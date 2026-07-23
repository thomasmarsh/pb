HA$PBExportHeader$listview.sru

global type listview from dragobject
end type

type variables
integer Accelerator
string AccessibleDescription
string AccessibleName
accessiblerole AccessibleRole
boolean AutoArrange
long BackColor
boolean Border
borderstyle BorderStyle
boolean BringToTop
boolean ButtonHeader
boolean CheckBoxes
powerobject ClassDefinition
boolean DeleteItems
boolean DragAuto
string DragIcon
boolean EditLabels
boolean Enabled
boolean ExtendedSelect
string FaceName
boolean FixedLocations
fontcharset FontCharSet
fontfamily FontFamily
fontpitch FontPitch
boolean FullRowSelect
boolean GridLines
boolean HeaderDragDrop
integer Height
boolean HideSelection
integer ImeMode
boolean Italic
string Item[]
integer ItemPictureIndex[]
boolean LabelWrap
integer LargePictureHeight
long LargePictureMaskColor
string LargePictureName[]
integer LargePictureWidth
boolean LayoutRTL
boolean OneClickActivate
string Pointer
boolean RightToLeft
boolean Scrolling
boolean ShowHeader
integer SmallPictureHeight
long SmallPictureMaskColor
string SmallPictureName[]
integer SmallPictureWidth
grsorttype SortType
integer StatePictureHeight
long StatePictureMaskColor
string StatePictureName[]
integer StatePictureWidth
integer TabOrder
string Tag
long TextColor
integer TextSize
boolean TrackSelect
boolean TwoClickActivate
boolean Underline
boolean UnderlineCold
boolean UnderlineHot
listviewview View
boolean Visible
integer Weight
integer Width
integer X
integer Y
end variables

public function integer addcolumn (string label, any alignment, integer width)
end function

public function integer additem ()
end function

public function integer addlargepicture (any picturename)
end function

public function integer addsmallpicture (listview picturename)
end function

public function integer addstatepicture (any picturename)
end function

public function integer arrange ()
end function

public function string classname ()
end function

public function integer deletecolumn (any index)
end function

public function integer deletecolumns ()
end function

public function integer deleteitem ()
end function

public function integer deleteitems ()
end function

public function integer deletelargepicture (any index)
end function

public function integer deletelargepictures ()
end function

public function integer deletesmallpicture (any index)
end function

public function integer deletesmallpictures ()
end function

public function integer deletestatepicture (any index)
end function

public function integer deletestatepictures ()
end function

public function integer drag (dragmodes m)
end function

public function integer editlabel ()
end function

public function integer finditem ()
end function

public function integer getcolumn (integer index, string label, any alignment, integer width)
end function

public function integer getcontextservice (string servicename, powerobject servicereference)
end function

public function integer getitem ()
end function

public function integer getorigin (listview x, listview y)
end function

public function powerobject getparent ()
end function

public function integer hide ()
end function

public function integer insertcolumn (integer index, string label, any alignment, integer width)
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

public function integer resize (any width, any height)
end function

public function integer selectedindex ()
end function

public function integer setcolumn (any index, any label, any alignment, any width)
end function

public function integer setfocus ()
end function

public function integer setitem ()
end function

public function integer setoverlaypicture (any overlayindex, any imageindex)
end function

public function integer setposition ()
end function

public function integer setredraw ()
end function

public function integer show ()
end function

public function integer sort ()
end function

public function integer totalcolumns ()
end function

public function integer totalitems ()
end function

public function integer totalselected ()
end function

public function integer triggerevent (string event, long word, long long)
end function

public function any typeof ()
end function

on listview.begindrag
end on

on listview.beginlabeledit
end on

on listview.beginrightdrag
end on

on listview.clicked
end on

on listview.columnclick
end on

on listview.constructor
end on

on listview.deleteallitems
end on

on listview.deleteitem
end on

on listview.destructor
end on

on listview.doubleclicked
end on

on listview.dragdrop
end on

on listview.dragenter
end on

on listview.dragleave
end on

on listview.dragwithin
end on

on listview.endlabeledit
end on

on listview.getfocus
end on

on listview.insertitem
end on

on listview.itemactivate
end on

on listview.itemchanged
end on

on listview.itemchanging
end on

on listview.key
end on

on listview.losefocus
end on

on listview.rightclicked
end on

on listview.rightdoubleclicked
end on

on listview.sort
end on
