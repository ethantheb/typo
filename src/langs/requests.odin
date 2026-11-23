package langs

// Requests about a document's text: which of its servers is asked, and
// matching each response to the document and client it was about (the app
// handles it through env.response). Requests and answers are byte offsets; the
// client's thread converts them to and from the server's positions

import "../lsp"
import "../uitime"


// A request waiting for its response
Request :: struct {
	client:  ^Client,
	conn:    ^lsp.Client, // the client as it ran then; after a restart it is stale
	id:      int,
	feature: lsp.Feature,
	doc:     ^Doc, // nil for a request about the workspace
	offset:  int,
}


// The first of the document's running servers that can do `feature`, or nil
client_with :: proc(d: ^Doc, feature: lsp.Feature) -> ^Client {
	for dc in d.clients {
		c := dc.client
		if !dc.opened || c.state != .Running {
			continue
		}

		if lsp.has_feature(c.caps, feature) do return c
	}
	return nil
}


// Asks a client about the text at `offset` of a document (method takes a
// document and a position), or about the whole document. Returns the request's
// id
send_request :: proc(
	d: ^Doc,
	c: ^Client,
	feature: lsp.Feature,
	method: string,
	offset: int,
) -> int {
	id := lsp.request(c.client, method, d.uri, offset)
	track_request(d, c, feature, id, offset)
	return id
}


// Remembers a request sent about a document's text (or the workspace's, with
// no document), for its response
track_request :: proc(d: ^Doc, c: ^Client, feature: lsp.Feature, id, offset: int) {
	request := Request {
		client  = c,
		conn    = c.client,
		id      = id,
		feature = feature,
		doc     = d,
		offset  = offset,
	}
	append(&state.requests, request)
}


// Drops the requests about a document (it is closing), cancelling them
requests_forget :: proc(d: ^Doc) {
	uitime.timed(&ui_share)
	for i := len(state.requests) - 1; i >= 0; i -= 1 {
		r := state.requests[i]
		if r.doc != d do continue

		if r.conn == r.client.client && r.client.state == .Running {
			lsp.cancel(r.client.client, r.id)
		}
		unordered_remove(&state.requests, i)
	}
}


// Drops a request whose answer is no longer wanted, telling its server
cancel_request :: proc(id: int, c: ^Client) {
	for r, i in state.requests {
		if r.id != id || r.client != c {
			continue
		}

		if r.conn == c.client && c.state == .Running {
			lsp.cancel(c.client, id)
		}
		unordered_remove(&state.requests, i)
		return
	}
}


// Whether a request is still waiting for its answer
request_waiting :: proc(id: int, c: ^Client) -> bool {
	for r in state.requests {
		if r.id == id && r.client == c {
			return true
		}
	}
	return false
}


// Drops a client's requests (it stopped, crashed, restarted or is going away)
requests_forget_client :: proc(c: ^Client) {
	for i := len(state.requests) - 1; i >= 0; i -= 1 {
		if state.requests[i].client == c do unordered_remove(&state.requests, i)
	}
}


// A response from a client: handed to the app with the request it answers,
// unless the client restarted since
@(private)
response :: proc(c: ^Client, resp: lsp.Response) {
	index := -1
	for r, i in state.requests {
		if r.client == c && r.conn == c.client && r.id == resp.id {
			index = i
			break
		}
	}
	if index < 0 do return

	r := state.requests[index]
	unordered_remove(&state.requests, index)
	env.response(c, r, resp)
}
