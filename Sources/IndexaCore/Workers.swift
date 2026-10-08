import Foundation

public actor AgentWorker {
    private let db:Database
    private let hermes:HermesClient
    private var busy=false
    public var paused=false
    public init(database:Database,hermes:HermesClient) { db=database;self.hermes=hermes }
    public func setPaused(_ value:Bool) { paused=value }
    public func tick(destination:String) async throws {
        guard !busy,!destination.isEmpty else { return }
        busy=true;defer { busy=false }
        guard let task=try await db.nextTask() else { return }
        if task.state == "queued" {
            guard !paused else { return }
            let capabilities=try await hermes.capabilities()
            guard let features=capabilities["features"] as? [String:Any],features["run_submission"] as? Bool == true,
                  features["run_status"] as? Bool == true else { throw IndexaError("hermes_capabilities_missing") }
            let durable=(features["runs_idempotency"] as? [String:Any])?["durable"] as? Bool == true
            let session=try await hermes.canonicalConversation()
            try await db.bindConversation(session)
            let payload:Data
            do {
                payload=try await Task.detached { [hermes] in try hermes.payload(input:task.text,session:session,attachments:task.attachments) }.value
            } catch {
                try await db.finish(task.id,state:"failed",result:Attachment.message(for:error),destination:destination,code:"attachment_unreadable")
                return
            }
            try await db.markSubmitting(task.id,payload:payload)
            do {
                let run:String
                do { run=try await hermes.submit(payload:payload,key:task.id) }
                catch let error as APIError where durable && (error.ambiguous || error.code < 0) {
                    // Same persisted payload and key, once, within the 24h retention window.
                    run=try await hermes.submit(payload:payload,key:task.id)
                }
                try await db.setRun(task.id,run:run)
            } catch let error as APIError where !error.ambiguous && error.code >= 400 && error.code < 500 && error.code != 409 {
                try await db.finish(task.id,state:"failed",result:"Indexa: Hermes odrzucił zadanie (\(error.code)).",destination:destination,code:"submit_\(error.code)")
            } catch {
                try await db.review(task.id,code:"submission_unknown")
                try await db.enqueue(event:task.id,kind:"unknown",destination:destination,body:"Indexa: nie znam stanu wykonania zadania \(task.id.prefix(8)). Kolejka została zatrzymana do sprawdzenia; nie powtarzam polecenia.")
            }
            return
        }
        guard let run=task.runID else { try await db.review(task.id,code:"missing_run_id");return }
        let status:RunStatus
        do { status=try await hermes.status(run) }
        catch let error as APIError where error.code == 404 { try await db.review(task.id,code:"run_not_found");return }
        catch let error as IndexaError where error.code == "unknown_run_state" { try await db.review(task.id,code:error.code);return }
        switch status.state {
        case "completed":
            guard let output=status.output,!output.isEmpty else { try await db.review(task.id,code:"completed_without_output");return }
            let identity=try await hermes.finalAnswerID(session:task.session,output:output,createdAt:status.createdAt,completedAt:status.completedAt)
            try await db.finish(task.id,state:"completed",result:output,destination:destination,deliveryEvent:identity)
        case "failed","cancelled","interrupted":
            let message=status.state == "failed" ? "Hermes zakończył zadanie błędem." : "Zadanie zostało przerwane. Wcześniejsze zmiany nie są cofane."
            try await db.finish(task.id,state:status.state,result:"Indexa · \(task.id.prefix(8))\n\(message)",destination:destination,code:status.state)
        case "waiting_for_approval":
            try await db.setRun(task.id,run:run,state:status.state)
            if let request=status.approvalID,let description=status.approvalDescription {
                try await db.addApproval(request:request,run:run,event:task.id,owner:destination,description:description)
            } else {
                try await db.enqueue(event:task.id,kind:"approval-unavailable",destination:destination,body:"Indexa: Hermes oczekuje zgody, ale nie udostępnił bezpiecznego opisu lub ID. Sprawdź zadanie na Macu; zgoda nie jest omijana.")
            }
        default: try await db.setRun(task.id,run:run,state:status.state == "started" ? "running" : status.state)
        }
    }
    public func cancel() async throws {
        guard let task=try await db.nextTask() else { return }
        if let run=task.runID { try await hermes.stop(run);try await db.setRun(task.id,run:run,state:"stopping") }
        else if task.state == "queued" {
            guard let owner=try await db.value("owner_chat") else { throw IndexaError("not_paired") }
            try await db.finish(task.id,state:"cancelled",result:"Indexa: anulowano zadanie przed wysłaniem do Hermesa.",destination:owner)
        } else { throw IndexaError("unknown_execution_state") }
    }
    public func approve(id:String,owner:String,choice:String) async throws {
        guard ["once","deny"].contains(choice) else { throw IndexaError("invalid_approval") }
        let approval=try await db.claimApproval(id,owner:owner)
        do {
            try await hermes.approve(run:approval.runID,request:approval.requestID,choice:choice)
            try await db.settleApproval(id,state:choice)
        } catch { try await db.settleApproval(id,state:"unknown");throw error }
    }
    public func expireApprovals() async throws {
        for a in try await db.approvals() where a.state == "pending" && a.expires <= Date().timeIntervalSince1970 {
            do { try await hermes.approve(run:a.runID,request:a.requestID,choice:"deny");try await db.settleApproval(a.id,state:"expired") }
            catch let e as APIError where e.code == 404 || e.code == 409 { try await db.settleApproval(a.id,state:"expired") }
        }
    }
}

public actor OutboxWorker {
    private let db:Database,matrix:MatrixClient
    private var busy=false
    public init(database:Database,matrix:MatrixClient) { db=database;self.matrix=matrix }
    public func tick() async throws {
        guard !busy else { return };busy=true;defer { busy=false }
        let now=Date().timeIntervalSince1970
        // Stable Matrix transaction IDs deduplicate retries, including a lost HTTP response.
        guard let item=try await db.nextDelivery(),
              ["pending","retry_wait"].contains(item.state),item.nextAttempt <= now else { return }
        try await db.setDelivery(item.id,state:"sending")
        do {
            let attachment:Attachment?
            if item.kind.contains(":attachment:") {
                guard let metadata=item.markup else { throw IndexaError("attachment_metadata_missing") }
                attachment=try JSONDecoder().decode(Attachment.self,from:Data(metadata.utf8))
            } else { attachment=nil }
            let message=try await matrix.send(id:item.id,room:item.destination,text:item.body,attachment:attachment)
            try await db.setDelivery(item.id,state:"delivered",messageID:message)
        } catch let e as APIError {
            if e.ambiguous || e.code == 429 || e.code == 408 || e.code >= 500 || e.code < 0 {
                let wait=e.retryAfter ?? min(300,pow(2,Double(min(item.attempts+1,8))))+Double.random(in:0...1)
                try await db.setDelivery(item.id,state:"retry_wait",next:now+max(1,wait))
            } else { try await db.setDelivery(item.id,state:"failed") }
        } catch { try await db.setDelivery(item.id,state:"failed") }
    }
}

public actor MatrixReceiver {
    private let db:Database,matrix:MatrixClient,worker:AgentWorker
    private var busy=false
    public init(database:Database,matrix:MatrixClient,worker:AgentWorker) { db=database;self.matrix=matrix;self.worker=worker }
    public func poll() async throws {
        guard !busy else { return };busy=true;defer { busy=false }
        guard let events=try await matrix.call("events")["events"] as? [[String:Any]] else { throw IndexaError("invalid_matrix_events") }
        let owner=try await db.value("owner_chat"),user=try await db.value("owner_user")
        for event in events {
            guard let id=event["id"] as? String,let room=event["room"] as? String,let sender=event["sender"] as? String,
                  let text=event["text"] as? String,!text.isEmpty,text.utf8.count <= 16384,
                  MatrixIdentity.allowed(room:room,user:sender,ownerRoom:owner,ownerUser:user) else { throw IndexaError("unauthorized_matrix_event") }
            let attachments=try (event["attachments"] as? [[String:Any]]).map { try JSONDecoder().decode([Attachment].self,from:JSONSerialization.data(withJSONObject:$0)) } ?? []
            guard attachments.count <= 1 else { throw IndexaError("invalid_matrix_attachments") }
            if event["attachment_error"] != nil {
                try await db.enqueue(event:id,kind:"attachment-error",destination:room,body:"Nie udało się odebrać załącznika. Obsługuję zdjęcia i dokumenty do 20 MB. Głosówki i wideo nie są jeszcze obsługiwane.")
            } else if attachments.isEmpty && (text.hasPrefix("!") || text.hasPrefix("/")) {
                if try await db.claimCommand(id) {
                    let pieces=text.split(whereSeparator:{$0.isWhitespace}).map(String.init)
                    var answer="Indexa: !status, !new, !cancel. Zwykła wiadomość kontynuuje rozmowę."
                    switch pieces.first {
                    case "!status","/status": answer=try await db.nextTask().map{"Indexa: \($0.state), zadanie \($0.id.prefix(8))."} ?? "Indexa: brak aktywnego zadania; szczegóły w aplikacji na Macu."
                    case "!new","/new":
                        answer="Indexa używa jednej wspólnej rozmowy w Hermesie i Matrixie. Napisz, od którego tematu zaczynamy."
                    case "!cancel","/cancel":
                        do { try await worker.cancel();answer="Wysłano żądanie zatrzymania. Wcześniejsze zmiany nie są cofane." } catch { answer="Nie potwierdziłem zatrzymania; sprawdź Indexa na Macu." }
                    case "!approve","/approve":
                        if pieces.count == 3,["once","deny"].contains(pieces[2]) {
                            do { try await worker.approve(id:pieces[1],owner:room,choice:pieces[2]);answer="Decyzja zapisana." }
                            catch { answer="Zgoda wygasła, była użyta lub ma niepewny stan. Sprawdź Indexa na Macu." }
                        }
                    default: break
                    }
                    try await db.enqueue(event:id,destination:room,body:answer)
                    try await db.setValue("matrix-command:"+id,"done")
                } else if try await db.value("matrix-command:"+id) == "processing" {
                    try await db.enqueue(event:id,destination:room,body:"Indexa: przerwano obsługę komendy; sprawdź stan na Macu. Nie ponawiam działania automatycznie.")
                }
            } else { _ = try await db.ingestMatrix(id:id,text:text,recorded:event["timestamp"] as? Double ?? Date().timeIntervalSince1970,attachments:attachments) }
            _ = try await matrix.call("ack",["id":id])
            if event["attachment_error"] != nil { _ = try? await matrix.call("feedback",["id":id,"state":"failed"]) }
            else if attachments.isEmpty && (text.hasPrefix("!") || text.hasPrefix("/")) { _ = try? await matrix.call("feedback",["id":id,"state":"completed"]) }
        }
    }
}
