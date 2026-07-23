HA$PBExportHeader$editmask.sru

global type editmask from dragobject
end type

type variables
integer Accelerator
string AccessibleDescription
string AccessibleName
accessiblerole AccessibleRole
alignment Alignment
boolean AutoHScroll
boolean AutoSkip
boolean AutoVScroll
long BackColor
boolean Border
borderstyle BorderStyle
boolean BringToTop
long CalendarBackColor
long CalendarTextColor
long CalendarTitleBackColor
long CalendarTitleTextColor
long CalendarTrailingTextColor
powerobject ClassDefinition
string DisplayData
boolean DisplayOnly
boolean DragAuto
string DragIcon
boolean DropDownCalendar
boolean DropDownRight
boolean Enabled
string FaceName
fontcharset FontCharSet
fontfamily FontFamily
fontpitch FontPitch
integer Height
boolean HideSelection
boolean HScrollBar
boolean IgnoreDefaultButton
integer ImeMode
double Increment
boolean Italic
integer Limit
string Mask
maskdatatype MaskDataType
string MinMax
string PlaceHolder
string Pointer
boolean RightToLeft
boolean Spin
integer TabOrder
integer TabStop[]
string Tag
string Text
textcase TextCase
long TextColor
integer TextSize
boolean Underline
boolean UseCodeTable
boolean Visible
boolean VScrollBar
integer Weight
integer Width
integer X
integer Y
end variables

public function boolean canundo ()
end function

public function string classname ()
end function

public function integer clear ()
end function

public function integer copy ()
end function

public function integer cut ()
end function

public function integer drag ()
end function

public function integer getcontextservice ()
end function

public function integer getdata ()
end function

public function powerobject getparent ()
end function

public function integer hide ()
end function

public function integer linecount ()
end function

public function integer linelength ()
end function

public function integer move ()
end function

public function integer paste ()
end function

public function integer pointerx ()
end function

public function integer pointery ()
end function

public function integer position ()
end function

public function boolean postevent ()
end function

public function integer print ()
end function

public function integer replacetext ()
end function

public function integer resize ()
end function

public function integer scroll ()
end function

public function integer selectedlength ()
end function

public function integer selectedline ()
end function

public function integer selectedstart ()
end function

public function string selectedtext ()
end function

public function integer selecttext ()
end function

public function integer setfocus ()
end function

public function integer setmask ()
end function

public function integer setposition ()
end function

public function integer setredraw ()
end function

public function integer show ()
end function

public function string textline ()
end function

public function integer triggerevent ()
end function

public function any typeof ()
end function

public function integer undo ()
end function

on editmask.constructor
end on

on editmask.destructor
end on

on editmask.dragdrop
end on

on editmask.dragenter
end on

on editmask.dragleave
end on

on editmask.dragwithin
end on

on editmask.getfocus
end on

on editmask.losefocus
end on

on editmask.modified
end on
