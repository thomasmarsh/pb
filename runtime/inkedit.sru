HA$PBExportHeader$inkedit.sru

global type inkedit from dragobject
end type

type variables
string AccessibleDescription
string AccessibleName
accessiblerole AccessibleRole
alignment Alignment
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
string Factoid
fontcharset FontCharSet
fontfamily FontFamily
fontpitch FontPitch
integer Height
boolean HScrollBar
boolean IgnorePressure
boolean InkAntiAliased
long InkColor
integer InkHeight
inkmode InkMode
integer InkTransparency
integer InkWidth
boolean InsertAsText
boolean Italic
integer Limit
boolean Modified
inkpentip PenTip
string Pointer
long RecognitionTimer
boolean RightToLeft
inkeditstatus Status
integer TabOrder
string Tag
string Text
long TextColor
integer TextSize
boolean Underline
boolean UseMouseForInput
boolean Visible
boolean VScrollBar
integer Weight
integer Width
integer X
integer Y
end variables

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

public function integer recognizetext ()
end function

public function integer replacetext (string string)
end function

public function integer resize (any width, any height)
end function

public function integer selectedlength ()
end function

public function string selectedtext ()
end function

public function long selecttext ()
end function

public function integer setfocus ()
end function

public function integer setposition ()
end function

public function integer setredraw ()
end function

public function integer show ()
end function

public function integer triggerevent (string event, long word, long long)
end function

public function any typeof ()
end function

on inkedit.constructor
end on

on inkedit.destructor
end on

on inkedit.dragdrop
end on

on inkedit.dragenter
end on

on inkedit.dragleave
end on

on inkedit.dragwithin
end on

on inkedit.gesture
end on

on inkedit.getfocus
end on

on inkedit.losefocus
end on

on inkedit.modified
end on

on inkedit.recognitionresult
end on

on inkedit.stroke
end on
