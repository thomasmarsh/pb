HA$PBExportHeader$listbox.sru

global type listbox from dragobject
end type

type variables
integer Accelerator
string AccessibleDescription
string AccessibleName
accessiblerole AccessibleRole
long BackColor
boolean Border
borderstyle BorderStyle
boolean BringToTop
powerobject ClassDefinition
boolean DisableNoScroll
boolean DragAuto
string DragIcon
boolean Enabled
boolean ExtendedSelect
string FaceName
fontcharset FontCharSet
fontfamily FontFamily
fontpitch FontPitch
integer Height
boolean HScrollBar
boolean Italic
string Item[]
boolean MultiSelect
string Pointer
boolean RightToLeft
boolean Sorted
integer TabOrder
integer TabStop[]
string Tag
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

public function integer additem ()
end function

public function string classname ()
end function

public function integer deleteitem ()
end function

public function boolean dirlist (string filespec, unsigned filetype, any statictext)
end function

public function boolean dirselect (string selection)
end function

public function integer drag (dragmodes m)
end function

public function integer finditem ()
end function

public function integer getcontextservice (string servicename, powerobject servicereference)
end function

public function powerobject getparent ()
end function

public function integer hide ()
end function

public function integer insertitem ()
end function

public function integer move (any x, any y)
end function

public function integer pointerx ()
end function

public function integer pointery ()
end function

public function boolean postevent (string event, long word, any long)
end function

public function integer print ()
end function

public function integer reset ()
end function

public function integer resize (any width, any height)
end function

public function integer selectedindex ()
end function

public function string selecteditem ()
end function

public function integer selectitem ()
end function

public function integer setfocus ()
end function

public function integer setposition ()
end function

public function integer setredraw ()
end function

public function integer setstate (any index, boolean state)
end function

public function integer settop (any index)
end function

public function integer show ()
end function

public function integer state (any index)
end function

public function string text ()
end function

public function integer top ()
end function

public function integer totalitems ()
end function

public function integer totalselected ()
end function

public function integer triggerevent (string event, long word, long long)
end function

public function any typeof ()
end function

on listbox.constructor
end on

on listbox.destructor
end on

on listbox.doubleclicked
end on

on listbox.dragdrop
end on

on listbox.dragenter
end on

on listbox.dragleave
end on

on listbox.dragwithin
end on

on listbox.getfocus
end on

on listbox.losefocus
end on

on listbox.selectionchanged
end on
