HA$PBExportHeader$monthcalendar.sru

global type monthcalendar from dragobject
end type

type variables
integer Accelerator
string AccessibleDescription
string AccessibleName
accessiblerole AccessibleRole
boolean AutoSize
long BackColor
boolean Border
borderstyle BorderStyle
boolean BringToTop
powerobject ClassDefinition
boolean DragAuto
string DragIcon
boolean Enabled
string FaceName
weekday FirstDayOfWeek
fontcharset FontCharSet
fontfamily FontFamily
fontpitch FontPitch
integer Height
boolean Italic
integer MaxSelectCount
long MonthBackColor
string Pointer
boolean RightToLeft
integer ScrollRate
integer TabOrder
string Tag
long TextColor
integer TextSize
long TitleBackColor
long TitleTextColor
boolean TodayCircle
boolean TodaySection
long TrailingTextColor
boolean Underline
boolean Visible
boolean WeekNumbers
integer Weight
integer Width
integer X
integer Y
end variables

public function string classname ()
end function

public function integer clearbolddates ()
end function

public function integer drag (dragmodes m)
end function

public function integer getcontextservice (string servicename, powerobject servicereference)
end function

public function integer getdatelimits (date min, date max)
end function

public function integer getdisplayrange (date start, date end, any d)
end function

public function powerobject getparent ()
end function

public function integer getselecteddate (date d)
end function

public function integer getselectedrange (date start, date end)
end function

public function date gettoday ()
end function

public function integer hide ()
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

public function integer setbolddate (date d, boolean onoff, any rt)
end function

public function integer setdatelimits (date min, date max)
end function

public function integer setfocus ()
end function

public function integer setposition ()
end function

public function integer setredraw ()
end function

public function integer setselecteddate (date d)
end function

public function integer setselectedrange (date start, date end)
end function

public function integer settoday (date d)
end function

public function integer show ()
end function

public function integer triggerevent (string event, long word, long long)
end function

public function any typeof ()
end function

on monthcalendar.clicked
end on

on monthcalendar.constructor
end on

on monthcalendar.datechanged
end on

on monthcalendar.dateselected
end on

on monthcalendar.destructor
end on

on monthcalendar.doubleclicked
end on

on monthcalendar.dragdrop
end on

on monthcalendar.dragenter
end on

on monthcalendar.dragleave
end on

on monthcalendar.dragwithin
end on

on monthcalendar.getfocus
end on

on monthcalendar.losefocus
end on
