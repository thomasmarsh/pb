HA$PBExportHeader$graphicobject.sru

global type graphicobject from windowobject
end type

type variables
integer x
integer y
integer width
integer height
boolean visible
boolean enabled
end variables

public subroutine Resize (integer ai_width, integer ai_height)
end subroutine

public subroutine Move (integer ai_x, integer ai_y)
end subroutine

public function boolean Hide ()
end function

public function boolean Show ()
end function
