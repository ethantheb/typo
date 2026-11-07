#+build windows
package editor

import "core:strings"
import win32 "core:sys/windows"

// Deleting to the Recycle Bin through the shell's IFileOperation, without its
// dialogs. The shell would delete an item it can't recycle (too big for the
// bin, or on a drive without one) for good; the progress sink stops it before
// anything is deleted, and the caller asks first.

move_to_trash :: proc(path: string) -> Delete_Result {
	hr := win32.CoInitializeEx(nil, .APARTMENTTHREADED)
	initialized := win32.SUCCEEDED(hr)
	defer if initialized do win32.CoUninitialize()

	op: ^IFileOperation
	if win32.FAILED(win32.CoCreateInstance(&CLSID_FileOperation, nil, win32.CLSCTX_INPROC_SERVER, &IID_IFileOperation, (^rawptr)(&op))) {
		return .Failed
	}
	defer op.Release((^win32.IUnknown)(op))

	native, _ := strings.replace_all(path, "/", `\`, context.temp_allocator)
	item: ^win32.IShellItem
	if win32.FAILED(win32.SHCreateItemFromParsingName(win32.utf8_to_wstring(native, context.temp_allocator), nil, win32.IID_IShellItem, (^rawptr)(&item))) {
		return .Failed
	}
	defer item.Release((^win32.IUnknown)(item))

	sink := Trash_Sink{sink = {Vtbl = &trash_sink_vtable}}
	cookie: win32.DWORD
	if win32.FAILED(op.SetOperationFlags(op, win32.FOF_NO_UI | win32.FOF_ALLOWUNDO | FOFX_RECYCLEONDELETE)) ||
	   win32.FAILED(op.Advise(op, &sink.sink, &cookie)) ||
	   win32.FAILED(op.DeleteItem(op, item, nil)) {
		return .Failed
	}
	hr = op.PerformOperations(op)
	op.Unadvise(op, cookie)
	if sink.permanent do return .Not_Recyclable
	aborted: win32.BOOL
	if win32.FAILED(hr) || win32.FAILED(op.GetAnyOperationsAborted(op, &aborted)) || aborted do return .Failed
	return .Done
}

@(private = "file")
FOFX_RECYCLEONDELETE :: 0x00080000

// PreDeleteItem's flags: the item goes to the Recycle Bin, else it is destroyed.
@(private = "file")
TSF_DELETE_RECYCLE_IF_POSSIBLE :: 0x80

@(private = "file")
CLSID_FileOperation := win32.GUID{0x3ad05575, 0x8857, 0x4850, {0x92, 0x77, 0x11, 0xb8, 0x5b, 0xdb, 0x8e, 0x09}}
@(private = "file")
IID_IFileOperation := win32.GUID{0x947aab5f, 0x0a5c, 0x4c13, {0xb4, 0xd6, 0x4b, 0xf7, 0x83, 0x6f, 0xc9, 0xf8}}
@(private = "file")
IID_IFileOperationProgressSink := win32.GUID{0x04b0f1a7, 0x9490, 0x44bc, {0x96, 0xe1, 0x42, 0x96, 0xa3, 0x12, 0x52, 0xe2}}
@(private = "file")
IID_IUnknown := win32.GUID{0x00000000, 0x0000, 0x0000, {0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}}

// IFileOperation (shobjidl_core.h); slots typo doesn't call are rawptr.
@(private = "file")
IFileOperation :: struct {
	using vtable: ^IFileOperation_VTable,
}

@(private = "file")
IFileOperation_VTable :: struct {
	using unknown:           win32.IUnknown_VTable,
	Advise:                  proc "system" (this: ^IFileOperation, sink: ^win32.IFileOperationProgressSink, cookie: ^win32.DWORD) -> win32.HRESULT,
	Unadvise:                proc "system" (this: ^IFileOperation, cookie: win32.DWORD) -> win32.HRESULT,
	SetOperationFlags:       proc "system" (this: ^IFileOperation, flags: win32.DWORD) -> win32.HRESULT,
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
	DeleteItem:              proc "system" (this: ^IFileOperation, item: ^win32.IShellItem, sink: ^win32.IFileOperationProgressSink) -> win32.HRESULT,
	DeleteItems:             rawptr,
	NewItem:                 rawptr,
	PerformOperations:       proc "system" (this: ^IFileOperation) -> win32.HRESULT,
	GetAnyOperationsAborted: proc "system" (this: ^IFileOperation, aborted: ^win32.BOOL) -> win32.HRESULT,
}

// The progress sink: lives on move_to_trash's stack, so references aren't
// counted.
@(private = "file")
Trash_Sink :: struct {
	sink:      win32.IFileOperationProgressSink, // first: COM sees a pointer to it
	permanent: bool,                             // an item would have been destroyed
}

@(private = "file")
S_OK :: win32.HRESULT(win32.S_OK)

@(private = "file")
E_ABORT := transmute(win32.HRESULT)u32(win32.E_ABORT)

@(private = "file")
E_NOINTERFACE := transmute(win32.HRESULT)u32(0x80004002)

@(private = "file")
trash_sink_vtable := win32.IFileOperationProgressSinkVtbl {
	IUnknownVtbl = {
		QueryInterface = proc "system" (this: ^win32.IUnknown, riid: win32.REFIID, out: ^rawptr) -> win32.HRESULT {
			if riid^ == IID_IUnknown || riid^ == IID_IFileOperationProgressSink {
				out^ = this
				return S_OK
			}
			out^ = nil
			return E_NOINTERFACE
		},
		AddRef = proc "system" (this: ^win32.IUnknown) -> win32.ULONG {return 1},
		Release = proc "system" (this: ^win32.IUnknown) -> win32.ULONG {return 1},
	},
	StartOperations = proc "system" (this: ^win32.IFileOperationProgressSink) -> win32.HRESULT {return S_OK},
	FinishOperations = proc "system" (this: ^win32.IFileOperationProgressSink, hr: win32.HRESULT) -> win32.HRESULT {return S_OK},
	PreRenameItem = proc "system" (this: ^win32.IFileOperationProgressSink, flags: win32.DWORD, item: ^win32.IShellItem, name: win32.LPCWSTR) -> win32.HRESULT {return S_OK},
	PostRenameItem = proc "system" (this: ^win32.IFileOperationProgressSink, flags: win32.DWORD, item: ^win32.IShellItem, name: win32.LPCWSTR, hr: win32.HRESULT, created: ^win32.IShellItem) -> win32.HRESULT {return S_OK},
	PreMoveItem = proc "system" (this: ^win32.IFileOperationProgressSink, flags: win32.DWORD, item: ^win32.IShellItem, dest: ^win32.IShellItem, name: win32.LPCWSTR) -> win32.HRESULT {return S_OK},
	PostMoveItem = proc "system" (this: ^win32.IFileOperationProgressSink, flags: win32.DWORD, item: ^win32.IShellItem, dest: ^win32.IShellItem, name: win32.LPCWSTR, hr: win32.HRESULT, created: ^win32.IShellItem) -> win32.HRESULT {return S_OK},
	PreCopyItem = proc "system" (this: ^win32.IFileOperationProgressSink, flags: win32.DWORD, item: ^win32.IShellItem, dest: ^win32.IShellItem, name: win32.LPCWSTR) -> win32.HRESULT {return S_OK},
	PostCopyItem = proc "system" (this: ^win32.IFileOperationProgressSink, flags: win32.DWORD, item: ^win32.IShellItem, dest: ^win32.IShellItem, name: win32.LPCWSTR, hr: win32.HRESULT, created: ^win32.IShellItem) -> win32.HRESULT {return S_OK},
	PreDeleteItem = proc "system" (this: ^win32.IFileOperationProgressSink, flags: win32.DWORD, item: ^win32.IShellItem) -> win32.HRESULT {
		if flags & TSF_DELETE_RECYCLE_IF_POSSIBLE != 0 do return S_OK
		(^Trash_Sink)(this).permanent = true
		return E_ABORT
	},
	PostDeleteItem = proc "system" (this: ^win32.IFileOperationProgressSink, flags: win32.DWORD, item: ^win32.IShellItem, hr: win32.HRESULT, created: ^win32.IShellItem) -> win32.HRESULT {return S_OK},
	PreNewItem = proc "system" (this: ^win32.IFileOperationProgressSink, flags: win32.DWORD, dest: ^win32.IShellItem, name: win32.LPCWSTR) -> win32.HRESULT {return S_OK},
	PostNewItem = proc "system" (this: ^win32.IFileOperationProgressSink, flags: win32.DWORD, dest: ^win32.IShellItem, name: win32.LPCWSTR, template: win32.LPCWSTR, attributes: win32.DWORD, hr: win32.HRESULT, created: ^win32.IShellItem) -> win32.HRESULT {return S_OK},
	UpdateProgress = proc "system" (this: ^win32.IFileOperationProgressSink, total: win32.UINT, done: win32.UINT) -> win32.HRESULT {return S_OK},
	ResetTimer = proc "system" (this: ^win32.IFileOperationProgressSink) -> win32.HRESULT {return S_OK},
	PauseTimer = proc "system" (this: ^win32.IFileOperationProgressSink) -> win32.HRESULT {return S_OK},
	ResumeTimer = proc "system" (this: ^win32.IFileOperationProgressSink) -> win32.HRESULT {return S_OK},
}
