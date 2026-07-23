HA$PBExportHeader$roundrectangle.sru

global type roundrectangle from drawobject
end type

type variables
powerobject ClassDefinition
integer CornerHeight
integer CornerWidth
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

public function integer resize (any width, any height)
end function

public function integer show ()
end function

public function any typeof ()
end function

on roundrectangle.constructor
end on

on roundrectangle.destructor
end on
