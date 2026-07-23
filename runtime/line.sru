HA$PBExportHeader$line.sru

global type line from drawobject
end type

type variables
integer BeginX
integer BeginY
powerobject ClassDefinition
integer EndX
integer EndY
long LineColor
linestyle LineStyle
integer LineThickness
string Tag
boolean Visible
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

public function integer resize ()
end function

public function integer show ()
end function

public function any typeof ()
end function

on line.constructor
end on

on line.destructor
end on
