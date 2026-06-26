HA$PBExportHeader$datawindow.sru

global type datawindow from dwobject
end type

type variables
integer x
integer y
integer width
integer height
boolean visible
boolean enabled
integer hscrollposition
integer vscrollposition
boolean hsplitscroll
end variables

public function integer SetBorderStyle (integer ai_style)
end function

public function integer Print ()
end function

public function string Object (string as_expr)
end function

on datawindow.itemchanged
end on

on datawindow.retrieveend
end on

on datawindow.rowfocuschanging
end on

on datawindow.buttonclicked
end on

on datawindow.clicked
end on

on datawindow.doubleclicked
end on
