import Foundation
import Testing
@testable import IndexaCore

struct TailscaleTests {
    @Test func webhookUsesExistingPrivateMatrixEndpoint() {
        let ready = TailscaleSnapshot(state: "Running", host: "indexa.ts.net", online: true, serve: true, funnel: false)
        #expect(ready.webhookURL == "https://indexa.ts.net:8443/pebble/v1/ingest")
        let missing = TailscaleSnapshot(state: "Running", host: "indexa.ts.net", online: true, serve: false, funnel: false)
        #expect(missing.webhookURL.isEmpty)
        let publicEndpoint = TailscaleSnapshot(state: "Running", host: "indexa.ts.net", online: true, serve: true, funnel: true)
        #expect(publicEndpoint.webhookURL.isEmpty)
    }
    @Test func onlyExistingPrivateHTTPSProxyProvidesWebhookURL() {
        let status: [String:Any] = ["BackendState":"Running", "Self":["Online":true, "DNSName":"indexa.ts.net."]]
        let configuration: [String:Any] = ["TCP":["8443":["HTTPS":true]],
            "Web":["indexa.ts.net:8443":["Handlers":["/":["Proxy":"http://127.0.0.1:18763"]]]]]
        let snapshot = TailscaleClient.snapshot(status:status, serveConfig:configuration)
        #expect(snapshot.webhookURL == "https://indexa.ts.net:8443/pebble/v1/ingest")
        #expect(snapshot.serve && !snapshot.funnel)
        for bad: [String:Any] in [[:],
            configuration.merging(["AllowFunnel":["indexa.ts.net:8443":true]]) { _,new in new },
            configuration.merging(["TCP":["8443":["HTTPS":false]]]) { _,new in new },
            configuration.merging(["Web":["indexa.ts.net:8443":["Handlers":["/":["Proxy":"http://127.0.0.1:9999"]]]]]) { _,new in new },
            configuration.merging(["Web":["indexa.ts.net:8443":["Handlers":["/":["Proxy":"http://127.0.0.1:18763"], "/pebble":["Proxy":"http://127.0.0.1:9999"]]]]]) { _,new in new }
        ] {
            #expect(TailscaleClient.snapshot(status:status, serveConfig:bad).webhookURL.isEmpty)
        }
        #expect(TailscaleClient.snapshot(status:[:], serveConfig:configuration).webhookURL.isEmpty)
        let offline = status.merging(["BackendState":"Stopped"]) { _,new in new }
        #expect(TailscaleClient.snapshot(status:offline, serveConfig:configuration).webhookURL.isEmpty)
    }
}
