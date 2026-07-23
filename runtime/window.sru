HA$PBExportHeader$window.sru

global type window from dragobject
end type

type variables
string AccessibleDescription
string AccessibleName
accessiblerole AccessibleRole
integer AnimationTime
long BackColor
boolean Border
boolean BringToTop
boolean Center
powerobject ClassDefinition
boolean ClientEdge
windowanimationstyle CloseAnimation
integer ColumnsPerPage
boolean ContextHelp
windowobject Control[]
boolean ControlMenu
boolean DisplayMenuAsRibbonBar
boolean Enabled
integer Height
boolean HScrollBar
string Icon
integer LinesPerPage
boolean MaxBox
boolean MaximizeAllTabbedSheets
menu MenuID
string MenuName
boolean MinBox
windowanimationstyle OpenAnimation
boolean PaletteWindow
string Pointer
string PowerTipText
boolean Resizable
boolean RightToLeft
string SheetListImage
boolean SheetListImageSize
string SheetListPanelText
string SheetListText
boolean SheetListVisible
boolean TabbedView
enumerated Tabs
string Tag
string Title
boolean TitleBar
toolbaralignment ToolbarAlignment
integer ToolbarHeight
boolean ToolbarVisible
integer ToolbarWidth
integer ToolbarX
integer ToolbarY
integer Transparency
integer UnitsPerColumn
integer UnitsPerLine
boolean Visible
boolean VScrollBar
integer Width
windowdockoptions WindowDockOptions
windowdockstate WindowDockState
windowstate WindowState
windowtype WindowType
integer X
integer Y
end variables

public function integer Open (string as_sheetname)
end function

public function integer Close (integer return_value)
end function

public function integer OpenSheet (window w, any mdi_frame, integer position)
end function

public subroutine SetFocus ()
end subroutine

public function integer Arrange (integer arrangeType)
end function

on window.open
end on

on window.close
end on

on window.resize
end on
