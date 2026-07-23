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

public function integer deletecheckbox ()
end function

public function integer deletecombobox ()
end function

public function integer deletegroup ()
end function

public function integer deleteitem ()
end function

public function integer deletelargebutton ()
end function

public function integer deletepanel ()
end function

public function integer deletesmallbutton ()
end function

public function integer deletetabbutton ()
end function

public function integer drag ()
end function

public function string exportjson ()
end function

public function integer exporttojsonfile ()
end function

public function integer exporttoxmlfile ()
end function

public function string exportxml ()
end function

public function integer getactivecategory ()
end function

public function integer getapplicationbutton ()
end function

public function integer getbestheight ()
end function

public function integer getcategory ()
end function

public function integer getcategorybyindex ()
end function

public function long getcategorycount ()
end function

public function long getcategoryindex ()
end function

public function integer getcheckbox ()
end function

public function integer getchilditembyindex ()
end function

public function long getchilditemcount ()
end function

public function integer getcombobox ()
end function

public function integer getcontextservice ()
end function

public function integer getgroup ()
end function

public function integer getitem ()
end function

public function integer getitembytag ()
end function

public function integer getitemparent ()
end function

public function integer getlargebutton ()
end function

public function integer getmenubybuttonhandle ()
end function

public function integer getpanel ()
end function

public function powerobject getparent ()
end function

public function integer getsmallbutton ()
end function

public function long gettabbutton ()
end function

public function integer gettabbuttonbyindex ()
end function

public function long gettabbuttoncount ()
end function

public function integer hide ()
end function

public function integer importfromjsonfile ()
end function

public function integer importfromxmlfile ()
end function

public function integer importjson ()
end function

public function integer importxml ()
end function

public function long insertcategory ()
end function

public function long insertcategoryfirst ()
end function

public function long insertcategorylast ()
end function

public function long insertcheckbox ()
end function

public function long insertcheckboxfirst ()
end function

public function long insertcheckboxlast ()
end function

public function long insertcombobox ()
end function

public function long insertcomboboxfirst ()
end function

public function long insertcomboboxlast ()
end function

public function long insertgroup ()
end function

public function long insertgroupfirst ()
end function

public function long insertgrouplast ()
end function

public function long insertlargebutton ()
end function

public function long insertlargebuttonfirst ()
end function

public function long insertlargebuttonlast ()
end function

public function long insertpanel ()
end function

public function long insertpanelfirst ()
end function

public function long insertpanellast ()
end function

public function long insertsmallbutton ()
end function

public function long insertsmallbuttonfirst ()
end function

public function long insertsmallbuttonlast ()
end function

public function long inserttabbutton ()
end function

public function long inserttabbuttonfirst ()
end function

public function long inserttabbuttonlast ()
end function

public function boolean isminimized ()
end function

public function integer move ()
end function

public function integer pointerx ()
end function

public function integer pointery ()
end function

public function boolean postevent ()
end function

public function integer print ()
end function

public function integer removeapplicationbutton ()
end function

public function integer replacecategorybyjson ()
end function

public function integer replacecategorybyxml ()
end function

public function integer resize ()
end function

public function integer setactivecategory ()
end function

public function integer setactivecategorybyindex ()
end function

public function integer setapplicationbutton ()
end function

public function integer setcategory ()
end function

public function integer setcheckbox ()
end function

public function integer setcombobox ()
end function

public function integer setfocus ()
end function

public function integer setgroup ()
end function

public function integer setitem ()
end function

public function integer setlargebutton ()
end function

public function long setminimized ()
end function

public function integer setpanel ()
end function

public function integer setposition ()
end function

public function integer setredraw ()
end function

public function integer setsmallbutton ()
end function

public function integer settabbutton ()
end function

public function integer show ()
end function

public function integer triggerevent ()
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
