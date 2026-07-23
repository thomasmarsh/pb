HA$PBExportHeader$tab.sru

global type tab from dragobject
end type

type variables
string AccessibleDescription
string AccessibleName
accessiblerole AccessibleRole
alignment Alignment
long BackColor
boolean BoldSelectedText
boolean BringToTop
powerobject ClassDefinition
userobject Control[]
boolean CreateOnDemand
boolean DragAuto
string DragIcon
boolean Enabled
string FaceName
boolean FixedWidth
boolean FocusOnButtonDown
fontcharset FontCharSet
fontfamily FontFamily
fontpitch FontPitch
integer Height
boolean Italic
boolean Multiline
boolean PerpendicularText
boolean PictureOnRight
string Pointer
boolean PowerTips
boolean RaggedRight
integer SelectedTab
boolean ShowPicture
boolean ShowText
integer TabOrder
tabposition TabPosition
string Tag
integer TextSize
boolean Underline
boolean Visible
integer Weight
integer Width
integer X
integer Y
end variables

public function string classname ()
end function

public function integer closetab (any userobjectvar)
end function

public function integer drag (dragmodes m)
end function

public function integer getcontextservice (string servicename, powerobject servicereference)
end function

public function powerobject getparent ()
end function

public function integer hide ()
end function

public function integer move (any x, any y)
end function

public function integer movetab (integer source, integer destination)
end function

public function integer opentab ()
end function

public function integer opentabwithparm ()
end function

public function integer pointerx ()
end function

public function integer pointery ()
end function

public function integer postevent (string event, long word, any long)
end function

public function integer print ()
end function

public function integer resize (any width, any height)
end function

public function integer selecttab (any tabidentifier)
end function

public function integer setfocus ()
end function

public function integer setposition ()
end function

public function integer setredraw ()
end function

public function integer show ()
end function

public function integer tabpostevent (string event, long word, any long)
end function

public function integer tabtriggerevent (string event, long word, long long)
end function

public function integer triggerevent (string event, long word, long long)
end function

public function any typeof ()
end function

on tab.clicked
end on

on tab.constructor
end on

on tab.destructor
end on

on tab.doubleclicked
end on

on tab.dragdrop
end on

on tab.dragenter
end on

on tab.dragleave
end on

on tab.dragwithin
end on

on tab.getfocus
end on

on tab.key
end on

on tab.losefocus
end on

on tab.rightclicked
end on

on tab.rightdoubleclicked
end on

on tab.selectionchanged
end on

on tab.selectionchanging
end on
