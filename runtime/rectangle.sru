HA$PBExportHeader$rectangle.sru

global type rectangle from drawobject
end type

type variables
powerobject ClassDefinition
long FillColor
fillpattern FillPattern
integer Height
long LineColor
linestyle LineStyle
integer LineThickness
string Tag
boolean Visible
integer Width
integer X
integer Y
end variables

public function string classname ()
end function

public function integer getcontextservice ()
end function

public function powerobject getparent ()
end function

public function integer hide ()
end function

public function integer move ()
end function

public function boolean postevent ()
end function

public function integer resize ()
end function

public function integer show ()
end function

public function integer triggerevent ()
end function

public function any typeof ()
end function

on rectangle.constructor
end on

on rectangle.destructor
end on
