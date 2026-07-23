HA$PBExportHeader$vscrollbar.sru

global type vscrollbar from dragobject
end type

type variables
string AccessibleDescription
string AccessibleName
accessiblerole AccessibleRole
boolean BringToTop
powerobject ClassDefinition
boolean DragAuto
string DragIcon
integer Height
integer MaxPosition
integer MinPosition
string Pointer
integer Position
boolean StdWidth
integer TabOrder
string Tag
boolean Visible
integer Width
integer X
integer Y
end variables

public function string classname ()
end function

public function integer drag ()
end function

public function integer getcontextservice ()
end function

public function powerobject getparent ()
end function

public function integer hide ()
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

public function integer resize ()
end function

public function integer setfocus ()
end function

public function integer setposition ()
end function

public function integer setredraw ()
end function

public function integer show ()
end function

public function integer triggerevent ()
end function

public function any typeof ()
end function

on vscrollbar.constructor
end on

on vscrollbar.destructor
end on

on vscrollbar.dragdrop
end on

on vscrollbar.dragenter
end on

on vscrollbar.dragleave
end on

on vscrollbar.dragwithin
end on

on vscrollbar.getfocus
end on

on vscrollbar.linedown
end on

on vscrollbar.lineup
end on

on vscrollbar.losefocus
end on

on vscrollbar.moved
end on

on vscrollbar.pagedown
end on

on vscrollbar.pageup
end on
