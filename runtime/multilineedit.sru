HA$PBExportHeader$multilineedit.sru

global type multilineedit from dragobject
end type

type variables
integer Accelerator
string AccessibleDescription
string AccessibleName
accessiblerole AccessibleRole
alignment Alignment
boolean AutoHScroll
boolean AutoVScroll
long BackColor
boolean Border
borderstyle BorderStyle
boolean BringToTop
powerobject ClassDefinition
boolean DisplayOnly
boolean DragAuto
string DragIcon
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
boolean Italic
integer Limit
string PlaceHolder
string Pointer
boolean RightToLeft
integer TabOrder
integer TabStop[]
string Tag
string Text
textcase TextCase
long TextColor
integer TextSize
boolean Underline
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

public function integer clear (boolean gridflag)
end function

public function integer copy ()
end function

public function integer cut ()
end function

public function integer drag (dragmodes m)
end function

public function integer getcontextservice (string servicename, powerobject servicereference)
end function

public function powerobject getparent ()
end function

public function integer hide ()
end function

public function integer linecount ()
end function

public function integer linelength ()
end function

public function integer move (any x, any y)
end function

public function integer paste ()
end function

public function integer pointerx ()
end function

public function integer pointery ()
end function

public function integer position (except RichTextEdit)
end function

public function boolean postevent (string event, long word, any long)
end function

public function integer print ()
end function

public function integer replacetext (string string)
end function

public function integer resize (any width, any height)
end function

public function integer scroll (long number)
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

public function integer setposition ()
end function

public function integer setredraw ()
end function

public function integer show ()
end function

public function string textline ()
end function

public function integer triggerevent (string event, long word, long long)
end function

public function any typeof ()
end function

public function integer undo ()
end function

on multilineedit.constructor
end on

on multilineedit.destructor
end on

on multilineedit.dragdrop
end on

on multilineedit.dragenter
end on

on multilineedit.dragleave
end on

on multilineedit.dragwithin
end on

on multilineedit.getfocus
end on

on multilineedit.losefocus
end on

on multilineedit.modified
end on
