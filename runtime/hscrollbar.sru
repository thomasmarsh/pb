HA$PBExportHeader$hscrollbar.sru

global type hscrollbar from dragobject
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
boolean StdHeight
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

on hscrollbar.constructor
end on

on hscrollbar.destructor
end on

on hscrollbar.dragdrop
end on

on hscrollbar.dragenter
end on

on hscrollbar.dragleave
end on

on hscrollbar.dragwithin
end on

on hscrollbar.getfocus
end on

on hscrollbar.lineleft
end on

on hscrollbar.lineright
end on

on hscrollbar.losefocus
end on

on hscrollbar.moved
end on

on hscrollbar.pageleft
end on

on hscrollbar.pageright
end on
