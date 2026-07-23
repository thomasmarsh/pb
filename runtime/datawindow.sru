HA$PBExportHeader$datawindow.sru

global type datawindow from dragobject
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
string AccessibleDescription
string AccessibleName
accessiblerole AccessibleRole
boolean Border
borderstyle BorderStyle
boolean BringToTop
powerobject ClassDefinition
boolean ControlMenu
string DataObject
boolean DragAuto
string DragIcon
boolean HScrollBar
string Icon
boolean LiveScroll
boolean MaxBox
boolean MinBox
dwobject Object
boolean Resizable
boolean RightToLeft
integer TabOrder
string Tag
string Title
boolean TitleBar
boolean VScrollBar
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
