HA$PBExportHeader$window.sru

global type window from dragobject
end type

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
