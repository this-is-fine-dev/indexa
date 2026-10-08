ObjC.import('Foundation');

function run() {
    const input = $.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile;
    const args = JSON.parse(ObjC.unwrap($.NSString.alloc.initWithDataEncoding(input, $.NSUTF8StringEncoding)));
    const notes = Application('Notes');
    const account = notes.defaultAccount();
    let folders = account.folders.whose({name: 'Indexa'})();
    if (folders.length === 0 && args.action === 'create') {
        account.folders.push(notes.Folder({name: 'Indexa'}));
        folders = account.folders.whose({name: 'Indexa'})();
    }
    if (folders.length !== 1) throw Error('indexa_folder_missing_or_ambiguous');
    const folder = folders[0];
    const html = text => text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/\n/g, '<br>');
    let note;
    if (args.action === 'create') {
        note = notes.Note({name: args.title, body: '<h1>' + html(args.title) + '</h1><div>' + html(args.text) + '</div>'});
        folder.notes.push(note);
    } else {
        const matches = folder.notes.whose({id: args.note_id})();
        if (matches.length !== 1) throw Error('exact_note_not_found');
        note = matches[0];
        if (args.action === 'append') note.body = note.body() + '<div><br></div><div>' + html(args.text) + '</div>';
        else if (args.action !== 'read') throw Error('invalid_action');
    }
    const id = note.id();
    const matches = folder.notes.whose({id: id})();
    if (matches.length !== 1) throw Error('readback_target_missing');
    const text = matches[0].plaintext();
    const normalize = s => s.replace(/\r\n/g, '\n').replace(/\u00a0/g, ' ').trim();
    if (args.action !== 'read' && !normalize(text).includes(normalize(args.text))) throw Error('readback_content_mismatch');
    return JSON.stringify({note_id:id, verified:true, text:args.action === 'read' ? text : undefined});
}
