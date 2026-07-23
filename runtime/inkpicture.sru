HA$PBExportHeader$inkpicture.sru

global type inkpicture from dragobject
end type

type variables
boolean AutoErase
long BackColor
boolean Border
borderstyle BorderStyle
boolean BringToTop
powerobject ClassDefinition
inkcollectionmode CollectionMode
boolean DragAuto
string DragIcon
boolean DynamicRendering
inkpiceditmode EditMode
boolean Enabled
integer EraserMode
integer EraserWidth
integer Height
boolean HighContrastInk
boolean IgnorePressure
boolean InkAntiAliased
long InkColor
boolean InkEnabled
string InkFileName
integer InkHeight
integer InkTransparency
integer InkWidth
integer MarginX
integer MarginY
inkpentip PenTip
string PictureFileName
displaysizemode PictureSizeMode
string Pointer
string PowerTipText
inkpicstatus Status
integer TabOrder
string Tag
boolean Visible
integer Width
integer X
integer Y
end variables

public function string classname ()
end function

public function integer drag ()
end function

public function integer getcontextservice ()
end function

public function powerobject getparent ()
end function

public function integer hide ()
end function

public function integer loadink ()
end function

public function integer loadpicture ()
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

public function integer resetink ()
end function

public function integer resetpicture ()
end function

public function integer resize ()
end function

public function integer save ()
end function

public function integer saveink ()
end function

public function integer setfocus ()
end function

public function integer setposition ()
end function

public function integer setredraw ()
end function

public function integer show ()
end function

public function integer triggerevent ()
end function

public function any typeof ()
end function

on inkpicture.constructor
end on

on inkpicture.destructor
end on

on inkpicture.dragdrop
end on

on inkpicture.dragenter
end on

on inkpicture.dragleave
end on

on inkpicture.dragwithin
end on

on inkpicture.gesture
end on

on inkpicture.getfocus
end on

on inkpicture.losefocus
end on

on inkpicture.stroke
end on
