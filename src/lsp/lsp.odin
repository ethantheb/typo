package lsp

// A Language Server Protocol client: starting servers, JSON-RPC over their
// stdin and stdout, the protocol types typo uses, and the table of known
// servers. Knows nothing about editors or UI: documents are URIs and text,
// places in them byte offsets (converted to the server's lines and columns
// here).
//
// None of it runs on the UI thread except queueing and taking. Each client has
// a thread of its own (worker.odin) that does the work, and its server process
// has three more: one reads its stdout and splits it into messages, one writes
// to its stdin, and one keeps its stderr for the log. Looking programs up on
// PATH and finding project roots also run on a thread (lookup.odin)


// Called from another thread when there is something for the UI thread
Notify_Proc :: #type proc "contextless" (userdata: rawptr)
