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

public function integer arrangesheets (any arrangetype)
end function

public function integer changemenu (any menuname, any position)
end function

public function integer closechannel (long handle, any windowhandle)
end function

public function integer closeuserobject (any targetobjectname)
end function

public function integer commitdocking ()
end function

public function integer execremote (any command, any applname, any topicname)
end function

public function any getactivesheet ()
end function

public function integer getcommanddde (string string)
end function

public function integer getcommandddeorigin (string applstring)
end function

public function integer getcontextservice (string servicename, powerobject servicereference)
end function

public function integer getdatadde (string string)
end function

public function integer getdataddeorigin (string applstring, string topicstring, string itemstring)
end function

public function any getfirstsheet ()
end function

public function any getnextsheet (any sheet)
end function

public function integer getremote (any location, any target, any applname, any topicname, any bansi)
end function

public function integer gettoolbar (integer toolbarindex, boolean visible, any alignment, string floatingtitle)
end function

public function integer gettoolbarpos (any toolbarindex, any dockrow, any offset)
end function

public function boolean ismaximizealltabbedsheetsenabled ()
end function

public function boolean istabbedviewenabled ()
end function

public function integer loaddockingstate (any regkey, string windowtypes, string sheetnames)
end function

public function long openchannel (string applname, string topicname, any windowhandle)
end function

public function integer opensheetasdocument (any sheetrefvar, string windowtype, any mdiframe, string sheetname, boolean tabalign)
end function

public function integer opensheetdocked (any sheetrefvar, string windowtype, any mdiframe, any position, string sheetname)
end function

public function integer opensheetfromdockingstate (any sheetrefvar, string windowtype, any mdiframe, string sheetname)
end function

public function integer opensheetintabgroup (any sheetrefvar, string windowtype, any siblingname, string sheetname)
end function

public function integer opensheetwithparm (any sheetrefvar, any parameter, string windowtype, any mdiframe, any position, any arrangeopen)
end function

public function integer opensheetwithparmasdocument (any sheetrefvar, any parameter, string windowtype, any mdiframe, string sheetname, boolean tabalign)
end function

public function integer opensheetwithparmdocked (any sheetrefvar, any parameter, string windowtype, any mdiframe, any position, string sheetname)
end function

public function integer opensheetwithparmfromdockingstate (any sheetrefvar, any parameter, string windowtype, any mdiframe, string sheetname)
end function

public function integer opensheetwithparmintabgroup (any sheetrefvar, any parameter, string windowtype, any siblingname, string sheetname)
end function

public function integer openuserobject (any targetobjectvar, any x, any y)
end function

public function integer openuserobjectwithparm (any targetobjectvar, any parameter, string targetobjecttype, any x, any y)
end function

public function any parentwindow ()
end function

public function integer pointerx ()
end function

public function integer pointery ()
end function

public function integer print (any printjobnumber, any x, any y, any width, any height)
end function

public function integer respondremote (boolean boolean)
end function

public function integer savedockingstate (any regkey)
end function

public function integer setdatadde (any string, any applname, string topic, string item)
end function

public function integer setmicrohelp (string string)
end function

public function integer setposition (any position, any precedingobject)
end function

public function integer setredraw (any boolean)
end function

public function integer setremote (string location, string value, long handle, any windowhandle, any bansi)
end function

public function integer setsheetid (string sheetname)
end function

public function integer settoolbar (integer toolbarindex, boolean visible, any alignment, string floatingtitle)
end function

public function integer settoolbarpos (any toolbarindex, any dockrow, any offset, any insert)
end function

public function integer starthotlink (string location, string applname, string topic, any bansi)
end function

public function integer startserverdde (any windowname, any applname, string topic, any item)
end function

public function integer stophotlink (string location, string applname, string topic)
end function

public function integer stopserverdde (any windowname, any applname, string topic)
end function

public function any typeof ()
end function

public function integer workspaceheight ()
end function

public function integer workspacewidth ()
end function

public function integer workspacex ()
end function

public function integer workspacey ()
end function

public function integer openwithparm (any windowvar, any parameter, string windowtype, any parent)
end function

public function integer closewithreturn (any windowname, any returnvalue)
end function

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
