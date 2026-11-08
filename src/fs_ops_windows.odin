#+build windows
package editor

import "core:strings"
import win32 "core:sys/windows"

// Deleting to the Recycle Bin through the shell's IFileOperation, without its
// dialogs. The shell would destroy an item it can't recycle (too big for the
// bin, or on a drive without one); the progress sink stops it before anything
// is deleted, and the caller asks first


move_to_trash :: proc(path: string) -> Delete_Result {
	hr := win32.CoInitializeEx(nil, .APARTMENTTHREADED)
	initialized := win32.SUCCEEDED(hr)
	defer if initialized do win32.CoUninitialize()

	// The operation, and the item to delete
	op: ^IFileOperation
	hr = win32.CoCreateInstance(
		&CLSID_FileOperation,
		nil,
		win32.CLSCTX_INPROC_SERVER,
		&IID_IFileOperation,
		(^rawptr)(&op),
	)
	if win32.FAILED(hr) do return .Failed
	defer op.Release((^win32.IUnknown)(op))

	native, _ := strings.replace_all(path, "/", `\`, context.temp_allocator)
	wide := win32.utf8_to_wstring(native, context.temp_allocator)
	item: ^win32.IShellItem
	hr = win32.SHCreateItemFromParsingName(wide, nil, win32.IID_IShellItem, (^rawptr)(&item))
	if win32.FAILED(hr) do return .Failed
	defer item.Release((^win32.IUnknown)(item))

	// Delete it, watched by the sink
	sink := Trash_Sink{sink = {Vtbl = &trash_sink_vtable}}
	cookie: win32.DWORD
	flags :: win32.FOF_NO_UI | win32.FOF_ALLOWUNDO | FOFX_RECYCLEONDELETE
	if win32.FAILED(op.SetOperationFlags(op, flags)) ||
	   win32.FAILED(op.Advise(op, &sink.sink, &cookie)) ||
	   win32.FAILED(op.DeleteItem(op, item, nil)) {
		return .Failed
	}
	hr = op.PerformOperations(op)
	op.Unadvise(op, cookie)

	if sink.permanent do return .Not_Recyclable

	aborted: win32.BOOL
	if win32.FAILED(hr) || win32.FAILED(op.GetAnyOperationsAborted(op, &aborted)) || aborted {
		return .Failed
	}
	return .Done
}


@(private = "file")
FOFX_RECYCLEONDELETE :: 0x00080000

// PreDeleteItem's flags: the item goes to the Recycle Bin, else it is destroyed
@(private = "file")
TSF_DELETE_RECYCLE_IF_POSSIBLE :: 0x80

@(private = "file")
S_OK :: win32.HRESULT(win32.S_OK)
@(private = "file")
E_ABORT := transmute(win32.HRESULT)u32(win32.E_ABORT)
@(private = "file")
E_NOINTERFACE := transmute(win32.HRESULT)u32(0x80004002)

@(private = "file")
CLSID_FileOperation := win32.GUID{
	0x3ad05575, 0x8857, 0x4850, {0x92, 0x77, 0x11, 0xb8, 0x5b, 0xdb, 0x8e, 0x09},
}
@(private = "file")
IID_IFileOperation := win32.GUID{
	0x947aab5f, 0x0a5c, 0x4c13, {0xb4, 0xd6, 0x4b, 0xf7, 0x83, 0x6f, 0xc9, 0xf8},
}
@(private = "file")
IID_IFileOperationProgressSink := win32.GUID{
	0x04b0f1a7, 0x9490, 0x44bc, {0x96, 0xe1, 0x42, 0x96, 0xa3, 0x12, 0x52, 0xe2},
}
@(private = "file")
IID_IUnknown := win32.GUID{
	0x00000000, 0x0000, 0x0000, {0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46},
}


// --- IFileOperation ----------------------------------------------------------------

// IFileOperation (shobjidl_core.h); slots typo doesn't call are rawptr
@(private = "file")
IFileOperation :: struct {
	using vtable: ^IFileOperation_VTable,
}

@(private = "file")
IFileOperation_VTable :: struct {
	using unknown:           win32.IUnknown_VTable,
	Advise:                  proc "system" (this: Op, sink: Sink, cookie: ^DWORD) -> HRESULT,
	Unadvise:                proc "system" (this: Op, cookie: DWORD) -> HRESULT,
	SetOperationFlags:       proc "system" (this: Op, flags: DWORD) -> HRESULT,
	SetProgressMessage:      rawptr,
	SetProgressDialog:       rawptr,
	SetProperties:           rawptr,
	SetOwnerWindow:          rawptr,
	ApplyPropertiesToItem:   rawptr,
	ApplyPropertiesToItems:  rawptr,
	RenameItem:              rawptr,
	RenameItems:             rawptr,
	MoveItem:                rawptr,
	MoveItems:               rawptr,
	CopyItem:                rawptr,
	CopyItems:               rawptr,
	DeleteItem:              proc "system" (this: Op, item: Item, sink: Sink) -> HRESULT,
	DeleteItems:             rawptr,
	NewItem:                 rawptr,
	PerformOperations:       proc "system" (this: Op) -> HRESULT,
	GetAnyOperationsAborted: proc "system" (this: Op, aborted: ^win32.BOOL) -> HRESULT,
}

@(private = "file")
Op :: ^IFileOperation


// --- The progress sink -------------------------------------------------------------

// Short names for the types the sink's callbacks take
@(private = "file")
Sink :: ^win32.IFileOperationProgressSink
@(private = "file")
Item :: ^win32.IShellItem
@(private = "file")
HRESULT :: win32.HRESULT
@(private = "file")
DWORD :: win32.DWORD
@(private = "file")
LPCWSTR :: win32.LPCWSTR

// Lives on move_to_trash's stack, so references aren't counted
@(private = "file")
Trash_Sink :: struct {
	sink:      win32.IFileOperationProgressSink, // first: COM sees a pointer to it
	permanent: bool,                             // an item would have been destroyed
}

// Stops the delete if the item can't go to the Recycle Bin
@(private = "file")
sink_pre_delete :: proc "system" (this: Sink, flags: DWORD, item: Item) -> HRESULT {
	if flags & TSF_DELETE_RECYCLE_IF_POSSIBLE != 0 do return S_OK

	(^Trash_Sink)(this).permanent = true
	return E_ABORT
}

@(private = "file")
sink_query :: proc "system" (this: ^win32.IUnknown, riid: win32.REFIID, out: ^rawptr) -> HRESULT {
	if riid^ == IID_IUnknown || riid^ == IID_IFileOperationProgressSink {
		out^ = this
		return S_OK
	}
	out^ = nil
	return E_NOINTERFACE
}

@(private = "file")
sink_ref :: proc "system" (this: ^win32.IUnknown) -> win32.ULONG {
	return 1
}

// The rest of the callbacks do nothing

@(private = "file")
sink_event :: proc "system" (this: Sink) -> HRESULT {
	return S_OK
}

@(private = "file")
sink_finish :: proc "system" (this: Sink, hr: HRESULT) -> HRESULT {
	return S_OK
}

@(private = "file")
sink_pre_rename :: proc "system" (this: Sink, flags: DWORD, item: Item, name: LPCWSTR) -> HRESULT {
	return S_OK
}

@(private = "file")
sink_post_rename :: proc "system" (
	this: Sink,
	flags: DWORD,
	item: Item,
	name: LPCWSTR,
	hr: HRESULT,
	created: Item,
) -> HRESULT {
	return S_OK
}

@(private = "file")
sink_pre_move :: proc "system" (
	this: Sink,
	flags: DWORD,
	item: Item,
	dest: Item,
	name: LPCWSTR,
) -> HRESULT {
	return S_OK
}

@(private = "file")
sink_post_move :: proc "system" (
	this: Sink,
	flags: DWORD,
	item: Item,
	dest: Item,
	name: LPCWSTR,
	hr: HRESULT,
	created: Item,
) -> HRESULT {
	return S_OK
}

@(private = "file")
sink_post_delete :: proc "system" (
	this: Sink,
	flags: DWORD,
	item: Item,
	hr: HRESULT,
	created: Item,
) -> HRESULT {
	return S_OK
}

@(private = "file")
sink_pre_new :: proc "system" (this: Sink, flags: DWORD, dest: Item, name: LPCWSTR) -> HRESULT {
	return S_OK
}

@(private = "file")
sink_post_new :: proc "system" (
	this: Sink,
	flags: DWORD,
	dest: Item,
	name: LPCWSTR,
	template: LPCWSTR,
	attributes: DWORD,
	hr: HRESULT,
	created: Item,
) -> HRESULT {
	return S_OK
}

@(private = "file")
sink_progress :: proc "system" (this: Sink, total: win32.UINT, done: win32.UINT) -> HRESULT {
	return S_OK
}

@(private = "file")
trash_sink_vtable := win32.IFileOperationProgressSinkVtbl{
	IUnknownVtbl     = {QueryInterface = sink_query, AddRef = sink_ref, Release = sink_ref},
	StartOperations  = sink_event,
	FinishOperations = sink_finish,
	PreRenameItem    = sink_pre_rename,
	PostRenameItem   = sink_post_rename,
	PreMoveItem      = sink_pre_move,
	PostMoveItem     = sink_post_move,
	PreCopyItem      = sink_pre_move,
	PostCopyItem     = sink_post_move,
	PreDeleteItem    = sink_pre_delete,
	PostDeleteItem   = sink_post_delete,
	PreNewItem       = sink_pre_new,
	PostNewItem      = sink_post_new,
	UpdateProgress   = sink_progress,
	ResetTimer       = sink_event,
	PauseTimer       = sink_event,
	ResumeTimer      = sink_event,
}
