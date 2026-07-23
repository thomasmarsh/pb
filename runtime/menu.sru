HA$PBExportHeader$menu.sru

global type menu from windowobject
end type

type variables
long BitmapBackColor
boolean BitmapGradient
string ButtonImage
integer ButtonImageSize
boolean Checked
powerobject ClassDefinition
boolean Default
boolean Enabled
string FaceName
boolean Italic
menu Item[]
boolean MenuAnimation
long MenuBackColor
boolean MenuBitmaps
long MenuHighlightColor
string MenuImage
menuitemtype MenuItemType
menustyle MenuStyle
long MenuTextColor
boolean MenuTitles
string MenuTitleText
menumergeoption MergeOption
string MicroHelp
string PanelImage
string PanelText
window ParentWindow
boolean ShiftToRight
integer Shortcut
string Tag
string Text
integer TextSize
long TitleBackColor
boolean TitleGradient
boolean ToolbarAnimation
long ToolbarBackColor
boolean ToolbarGradient
long ToolbarHighlightColor
integer ToolbarItemBarIndex
boolean ToolbarItemDown
string ToolbarItemDownName
string ToolbarItemName
integer ToolbarItemOrder
integer ToolbarItemSpace
string ToolbarItemText
boolean ToolbarItemVisible
toolbarstyle ToolbarStyle
long ToolbarTextColor
boolean Underline
boolean Visible
integer Weight
end variables

public function integer check ()
end function

public function string classname ()
end function

public function integer disable ()
end function

public function integer enable ()
end function

public function integer getcontextservice ()
end function

public function powerobject getparent ()
end function

public function integer hide ()
end function

public function integer popmenu ()
end function

public function integer postevent ()
end function

public function integer show ()
end function

public function integer triggerevent ()
end function

public function any typeof ()
end function

public function integer uncheck ()
end function

on menu.clicked
end on

on menu.constructor
end on

on menu.destructor
end on

on menu.help
end on

on menu.selected
end on
