HA$PBExportHeader$ribbonbar.sru

global type ribbonbar from dragobject
end type

type variables
string AccessibleDescription
string AccessibleName
accessiblerole AccessibleRole
boolean AutosizeHeight
boolean BringToTop
integer BuiltinTheme
powerobject ClassDefinition
boolean DragAuto
string DragIcon
boolean Enabled
string FaceName
fontcharset FontCharSet
fontfamily FontFamily
fontpitch FontPitch
integer Height
boolean HidePanelText
boolean HideTabHeader
boolean Italic
string Pointer
boolean RightToLeft
boolean ShowQuickAccessToolbar
integer TabOrder
string Tag
integer TextSize
integer Transparency
boolean Underline
boolean Visible
integer Weight
integer Width
integer X
integer Y
end variables

public function string classname ()
end function

public function integer deletecategory ()
end function

public function integer deletecheckbox (long ItemHandle)
end function

public function integer deletecombobox (long ItemHandle)
end function

public function integer deletegroup (long ItemHandle)
end function

public function integer deleteitem ()
end function

public function integer deletelargebutton (long ItemHandle)
end function

public function integer deletepanel (long ItemHandle)
end function

public function integer deletesmallbutton (long ItemHandle)
end function

public function integer deletetabbutton (long ItemHandle)
end function

public function integer drag (dragmodes m)
end function

public function string exportjson ()
end function

public function integer exporttojsonfile (string FileName, encoding encoding)
end function

public function integer exporttoxmlfile (string FileName, encoding encoding)
end function

public function string exportxml ()
end function

public function integer getactivecategory (ref ribboncategoryitem Item)
end function

public function integer getapplicationbutton (ref ribbonapplicationbuttonitem Item)
end function

public function integer getbestheight ()
end function

public function integer getcategory (long ItemHandle, ref ribboncategoryitem Item)
end function

public function integer getcategorybyindex (long Index, ref ribboncategoryitem Item)
end function

public function long getcategorycount ()
end function

public function long getcategoryindex (long ItemHandle)
end function

public function integer getcheckbox (long ItemHandle, ref ribboncheckboxitem Item)
end function

public function integer getchilditembyindex (long Handle, long Index, ref powerobject Item)
end function

public function long getchilditemcount (long Handle)
end function

public function integer getcombobox (long ItemHandle, ref ribboncomboboxitem Item)
end function

public function integer getcontextservice (string servicename, powerobject servicereference)
end function

public function integer getgroup (long ItemHandle, ref ribbongroupitem Item)
end function

public function integer getitem ()
end function

public function integer getitembytag (string Tag, ref powerobject Item)
end function

public function integer getitemparent (long ItemHandle, ref powerobject Item)
end function

public function integer getlargebutton (long ItemHandle, ref ribbonlargebuttonitem Item)
end function

public function integer getmenubybuttonhandle (long ItemHandle, ref ribbonapplicationmenu ApplicationMenu)
end function

public function integer getpanel (long ItemHandle, ref ribbonpanelitem Item)
end function

public function powerobject getparent ()
end function

public function integer getsmallbutton (long ItemHandle, ref ribbonsmallbuttonitem Item)
end function

public function long gettabbutton (long ItemHandle, ref ribbontabbuttonitem Item)
end function

public function integer gettabbuttonbyindex (long Index, ref ribbontabbuttonitem Item)
end function

public function long gettabbuttoncount ()
end function

public function integer hide ()
end function

public function integer importfromjsonfile (string filename)
end function

public function integer importfromxmlfile (string filename)
end function

public function integer importjson (string data)
end function

public function integer importxml (string data)
end function

public function long insertcategory ()
end function

public function long insertcategoryfirst (string Text)
end function

public function long insertcategorylast (string Text)
end function

public function long insertcheckbox (long ParentHandle, long ItemHandleAfter, string Text, string Clicked)
end function

public function long insertcheckboxfirst (long ParentHandle, string Text, string Clicked)
end function

public function long insertcheckboxlast (long ParentHandle, string Text, string Clicked)
end function

public function long insertcombobox (long ParentHandle, long ItemHandleAfter, string SelectionChanged)
end function

public function long insertcomboboxfirst (long ParentHandle, string SelectionChanged)
end function

public function long insertcomboboxlast (long ParentHandle, string SelectionChanged)
end function

public function long insertgroup (long PanelHandle, long ItemHandleAfter)
end function

public function long insertgroupfirst (long PanelHandle)
end function

public function long insertgrouplast (long PanelHandle)
end function

public function long insertlargebutton (long PanelHandle, long ItemHandleAfter, string Text, string PictureName, string Clicked)
end function

public function long insertlargebuttonfirst (long PanelHandle, string Text, string PictureName, string Clicked)
end function

public function long insertlargebuttonlast (long PanelHandle, string Text, string PictureName, string Clicked)
end function

public function long insertpanel (long CategoryHandle, long ItemHandleAfter, string Text, string PictureName)
end function

public function long insertpanelfirst (long CategoryHandle, string Text, string PictureName)
end function

public function long insertpanellast (long CategoryHandle, string Text, string PictureName)
end function

public function long insertsmallbutton (long ParentHandle, long ItemHandleAfter, string Text, string PictureName, string Clicked)
end function

public function long insertsmallbuttonfirst (long ParentHandle, string Text, string PictureName, string Clicked)
end function

public function long insertsmallbuttonlast (long ParentHandle, string Text, string PictureName, string Clicked)
end function

public function long inserttabbutton (long ItemHandleAfter, string Text, string PictureName, string Clicked)
end function

public function long inserttabbuttonfirst (string Text, string PictureName, string Clicked)
end function

public function long inserttabbuttonlast (string Text, string PictureName, string Clicked)
end function

public function boolean isminimized ()
end function

public function integer move (any x, any y)
end function

public function integer pointerx ()
end function

public function integer pointery ()
end function

public function boolean postevent (string event, long word, any long)
end function

public function integer print ()
end function

public function integer removeapplicationbutton ()
end function

public function integer replacecategorybyjson (long itemhandle, string data)
end function

public function integer replacecategorybyxml (long itemhandle, string data)
end function

public function integer resize (any width, any height)
end function

public function integer setactivecategory (long ItemHandle)
end function

public function integer setactivecategorybyindex (long Index)
end function

public function integer setapplicationbutton (ribbonapplicationbuttonitem Item)
end function

public function integer setcategory (long ItemHandle, ribboncategoryitem Item)
end function

public function integer setcheckbox (long ItemHandle, ribboncheckboxitem Item)
end function

public function integer setcombobox (long ItemHandle, ribboncomboboxitem Item)
end function

public function integer setfocus ()
end function

public function integer setgroup (long ItemHandle, ribbongroupitem Item)
end function

public function integer setitem ()
end function

public function integer setlargebutton (long ItemHandle, ribbonlargebuttonitem Item)
end function

public function long setminimized (boolean Minimized)
end function

public function integer setpanel (long ItemHandle, ribbonpanelitem Item)
end function

public function integer setposition ()
end function

public function integer setredraw ()
end function

public function integer setsmallbutton (long ItemHandle, ribbonsmallbuttonitem Item)
end function

public function integer settabbutton (long ItemHandle, ribbontabbuttonitem Item)
end function

public function integer show ()
end function

public function integer triggerevent (string event, long word, long long)
end function

public function any typeof ()
end function

on ribbonbar.categorycollapsed
end on

on ribbonbar.categoryexpanded
end on

on ribbonbar.categoryselectionchanged
end on

on ribbonbar.categoryselectionchanging
end on

on ribbonbar.constructor
end on

on ribbonbar.destructor
end on

on ribbonbar.itemunselected
end on

on ribbonbar.menuchanged
end on
