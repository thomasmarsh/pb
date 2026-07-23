HA$PBExportHeader$treeview.sru

global type treeview from dragobject
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
boolean CheckBoxes
powerobject ClassDefinition
boolean DeleteItems
boolean DisableDragDrop
boolean DragAuto
string DragIcon
boolean EditLabels
boolean Enabled
string FaceName
fontcharset FontCharSet
fontfamily FontFamily
fontpitch FontPitch
boolean FullRowSelect
boolean HasButtons
boolean HasLines
integer Height
boolean HideSelection
integer ImeMode
integer Indent
boolean Italic
boolean LayoutRTL
boolean LinesAtRoot
integer PictureHeight
long PictureMaskColor
string PictureName[]
integer PictureWidth
string Pointer
boolean RightToLeft
boolean SingleExpand
grsorttype SortType
integer StatePictureHeight
long StatePictureMaskColor
string StatePictureName[]
integer StatePictureWidth
integer TabOrder
string Tag
long TextColor
integer TextSize
boolean ToolTips
boolean TrackSelect
boolean Underline
boolean Visible
integer Weight
integer Width
integer X
integer Y
end variables

public function integer addpicture ()
end function

public function integer addstatepicture ()
end function

public function string classname ()
end function

public function integer collapseitem ()
end function

public function integer deleteitem ()
end function

public function integer deletepicture ()
end function

public function integer deletepictures ()
end function

public function integer deletestatepicture ()
end function

public function integer deletestatepictures ()
end function

public function integer drag ()
end function

public function integer editlabel ()
end function

public function integer expandall ()
end function

public function integer expanditem ()
end function

public function long finditem ()
end function

public function integer getcontextservice ()
end function

public function integer getitem ()
end function

public function integer getitematpointer ()
end function

public function powerobject getparent ()
end function

public function integer hide ()
end function

public function long insertitem ()
end function

public function long insertitemfirst ()
end function

public function long insertitemlast ()
end function

public function long insertitemsort ()
end function

public function integer move ()
end function

public function integer pointerx ()
end function

public function integer pointery ()
end function

public function boolean postevent ()
end function

public function integer print ()
end function

public function integer resize ()
end function

public function integer selectitem ()
end function

public function integer setdrophighlight ()
end function

public function integer setfirstvisible ()
end function

public function integer setfocus ()
end function

public function integer setitem ()
end function

public function integer setlevelpictures ()
end function

public function integer setoverlaypicture ()
end function

public function integer setposition ()
end function

public function integer setredraw ()
end function

public function integer show ()
end function

public function integer sort ()
end function

public function integer sortall ()
end function

public function integer triggerevent ()
end function

public function any typeof ()
end function

on treeview.begindrag
end on

on treeview.beginlabeledit
end on

on treeview.beginrightdrag
end on

on treeview.clicked
end on

on treeview.constructor
end on

on treeview.deleteitem
end on

on treeview.destructor
end on

on treeview.doubleclicked
end on

on treeview.dragdrop
end on

on treeview.dragenter
end on

on treeview.dragleave
end on

on treeview.dragwithin
end on

on treeview.endlabeledit
end on

on treeview.getfocus
end on

on treeview.itemcollapsed
end on

on treeview.itemcollapsing
end on

on treeview.itemexpanded
end on

on treeview.itemexpanding
end on

on treeview.itempopulate
end on

on treeview.key
end on

on treeview.losefocus
end on

on treeview.notify
end on

on treeview.rightclicked
end on

on treeview.rightdoubleclicked
end on

on treeview.selectionchanged
end on

on treeview.selectionchanging
end on

on treeview.sort
end on
