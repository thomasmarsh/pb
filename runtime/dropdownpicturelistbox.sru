HA$PBExportHeader$dropdownpicturelistbox.sru

global type dropdownpicturelistbox from dragobject
end type

type variables
integer Accelerator
string AccessibleDescription
string AccessibleName
accessiblerole AccessibleRole
boolean AllowEdit
boolean AutoHScroll
long BackColor
boolean Border
borderstyle BorderStyle
boolean BringToTop
powerobject ClassDefinition
boolean DragAuto
string DragIcon
boolean Enabled
string FaceName
fontcharset FontCharSet
fontfamily FontFamily
fontpitch FontPitch
integer Height
boolean HScrollBar
integer ImeMode
boolean Italic
string Item[]
integer ItemPictureIndex[]
integer Limit
integer PictureHeight
long PictureMaskColor
string PictureName[]
integer PictureWidth
string Pointer
boolean RightToLeft
boolean ShowList
boolean Sorted
integer TabOrder
string Tag
string Text
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

public function integer addpicture (any picturename)
end function

public function string classname ()
end function

public function integer clear (boolean gridflag)
end function

public function integer copy ()
end function

public function integer cut ()
end function

public function integer deleteitem ()
end function

public function integer deletepicture (treeview index)
end function

public function integer deletepictures ()
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

public function integer reset ()
end function

public function integer resize (any width, any height)
end function

public function integer selectedlength ()
end function

public function integer selectedstart ()
end function

public function string selectedtext ()
end function

public function integer selectitem ()
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

public function string text ()
end function

public function integer totalitems ()
end function

public function integer triggerevent (string event, long word, long long)
end function

public function any typeof ()
end function

on dropdownpicturelistbox.constructor
end on

on dropdownpicturelistbox.destructor
end on

on dropdownpicturelistbox.doubleclicked
end on

on dropdownpicturelistbox.dragdrop
end on

on dropdownpicturelistbox.dragenter
end on

on dropdownpicturelistbox.dragleave
end on

on dropdownpicturelistbox.dragwithin
end on

on dropdownpicturelistbox.getfocus
end on

on dropdownpicturelistbox.losefocus
end on

on dropdownpicturelistbox.modified
end on

on dropdownpicturelistbox.selectionchanged
end on
