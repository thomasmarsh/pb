HA$PBExportHeader$webbrowser.sru

global type webbrowser from dragobject
end type

type variables
string AccessibleDescription
string AccessibleName
accessiblerole AccessibleRole
boolean Border
borderstyle BorderStyle
boolean BringToTop
powerobject ClassDefinition
boolean ContextMenu
string DefaultUrl
boolean DevTools
boolean DragAuto
string DragIcon
boolean Enabled
integer Height
boolean PasswordAutosave
boolean PopupWindow
integer TabOrder
string Tag
integer Transparency
boolean Visible
integer Width
integer X
integer Y
end variables

public function integer canceldownload (integer ItemId)
end function

public function string classname ()
end function

public function integer clearbrowsingdata (browsingdatakinds datakinds)
end function

public function integer closedefaultdownloaddialog ()
end function

public function integer drag (dragmodes m)
end function

public function integer evaluatejavascriptasync (string script)
end function

public function integer evaluatejavascriptsync (string script, ref string result, ref string error)
end function

public function integer getcontextservice (string servicename, powerobject servicereference)
end function

public function powerobject getparent ()
end function

public function string getsource ()
end function

public function integer goback ()
end function

public function integer goforward ()
end function

public function integer hide ()
end function

public function integer move (any x, any y)
end function

public function integer navigate (string url)
end function

public function integer navigatetostring (string html)
end function

public function integer opendefaultdownloaddialog ()
end function

public function integer pausedownload (integer ItemId)
end function

public function integer pointerx ()
end function

public function integer pointery ()
end function

public function boolean postevent (string event, long word, any long)
end function

public function integer postjsonwebmessage (sring json)
end function

public function integer poststringwebmessage (sring webmessage)
end function

public function integer print ()
end function

public function integer printaspdf (string PdfFile)
end function

public function integer refresh ()
end function

public function integer registerevent (string eventname)
end function

public function integer resize (any width, any height)
end function

public function integer resumedownload (integer ItemId)
end function

public function integer setfocus ()
end function

public function integer setposition ()
end function

public function integer setredraw ()
end function

public function integer show ()
end function

public function integer stopnavigation ()
end function

public function integer triggerevent (string event, long word, long long)
end function

public function any typeof ()
end function

public function integer unregisterevent (string eventname)
end function

public function integer zoom (integer zoomlevel)
end function

on webbrowser.acceleratorkeypressed
end on

on webbrowser.addresschange
end on

on webbrowser.certificateerror
end on

on webbrowser.constructor
end on

on webbrowser.contentloading
end on

on webbrowser.domcontentloaded
end on

on webbrowser.destructor
end on

on webbrowser.downloadingoperationstatechanged
end on

on webbrowser.downloadingstart
end on

on webbrowser.downloadingstatechanged
end on

on webbrowser.estimatedendtimechanged
end on

on webbrowser.evaluatejavascriptfinished
end on

on webbrowser.getfocus
end on

on webbrowser.historychanged
end on

on webbrowser.isdefaultdownloaddialogstatechanged
end on

on webbrowser.losefocus
end on

on webbrowser.navigationcompleted
end on

on webbrowser.navigationerror
end on

on webbrowser.navigationprogressindex
end on

on webbrowser.navigationstart
end on

on webbrowser.navigationstatechanged
end on

on webbrowser.pdfprintfinished
end on

on webbrowser.resourceredirect
end on

on webbrowser.titletextchanged
end on

on webbrowser.webmessagereceived
end on
