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

public function integer getcontextservice (string servicename, powerobject servicereference)
end function

public function powerobject getparent ()
end function

public function integer hide ()
end function

public function integer move (any x, any y)
end function

public function boolean postevent (string event, long word, any long)
end function

public function integer resize (any width, any height)
end function

public function integer show ()
end function

public function integer triggerevent (string event, long word, long long)
end function

public function any typeof ()
end function

on rectangle.constructor
end on

on rectangle.destructor
end on
