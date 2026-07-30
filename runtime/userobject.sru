HA$PBExportHeader$userobject.sru

global type userobject from dragobject
end type

type variables
long BackColor
boolean Border
borderstyle BorderStyle
boolean BringToTop
powerobject ClassDefinition
string ClassName
integer ColumnsPerPage
windowobject Control[]
boolean DragAuto
string DragIcon
boolean Enabled
integer Height
boolean HScrollBar
string LibraryName
integer LinesPerPage
userobjects ObjectType
long PictureMaskColor
string PictureName
string Pointer
string PowerTipText
long Style
long TabBackColor
integer TabOrder
long TabTextColor
string Tag
string Text
integer UnitsPerColumn
integer UnitsPerLine
boolean Visible
boolean VScrollBar
integer Width
integer X
integer Y
end variables

public function integer additem (any item)
end function

public function integer closeuserobject (any targetobjectname)
end function

public function integer createpage ()
end function

public function integer deleteitem (any index)
end function

public function integer drag (dragmodes m)
end function

public function integer getcontextservice (string servicename, powerobject servicereference)
end function

public function integer insertitem (any item, any index)
end function

public function integer openuserobject (any targetobjectvar, any x, any y)
end function

public function integer openuserobjectwithparm (any targetobjectvar, any parameter, string targetobjecttype, any x, any y)
end function

public function boolean pagecreated ()
end function

public function integer pointerx ()
end function

public function integer pointery ()
end function

public function integer print (any printjobnumber, any x, any y, any width, any height)
end function

public function integer setfocus ()
end function

public function integer setposition (any position, any precedingobject)
end function

public function integer setredraw (any boolean)
end function

public function any typeof ()
end function
