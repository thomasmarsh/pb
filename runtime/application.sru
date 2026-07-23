HA$PBExportHeader$application.sru

global type application from nonvisualobject
end type

type variables
string AppName
powerobject ClassDefinition
integer DDETimeOut
string DisplayName
string DWMessageTitle
boolean FreeDBLibraries
integer HighDPIMode
string MicroHelpDefault
boolean RightToLeft
string ToolbarFrameTitle
string ToolbarPopMenuText
string ToolbarSheetTitle
boolean ToolbarText
boolean ToolbarTips
boolean ToolbarUserControl
end variables

public function integer beginsession ()
end function

public function string classname ()
end function

public function integer getcontextservice ()
end function

public function string gethttprequestheader ()
end function

public function string gethttprequestheaders ()
end function

public function string gethttpresponseheaders ()
end function

public function long gethttpresponsestatuscode ()
end function

public function string gethttpresponsestatustext ()
end function

public function powerobject getparent ()
end function

public function string getpowerserverurl ()
end function

public function string getquickaccesstoolbarstatuspath ()
end function

public function string getsessionid ()
end function

public function boolean postevent ()
end function

public function integer sethighdpimode ()
end function

public function integer sethttprequestheader ()
end function

public function integer setlibrarylist ()
end function

public function integer setpowerserverurl ()
end function

public function integer setquickaccesstoolbarstatuspath ()
end function

public function integer settranspool ()
end function

public function integer triggerevent ()
end function

public function any typeof ()
end function

on application.close
end on

on application.constructor
end on

on application.destructor
end on

on application.idle
end on

on application.open
end on

on application.sessioncreating
end on

on application.systemerror
end on
