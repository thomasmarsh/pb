HA$PBExportHeader$dwobject.sru

global type dwobject from powerobject
end type

public function long Retrieve ()
end function

public function integer Update ()
end function

public subroutine SetTransObject (transaction tr)
end subroutine

public subroutine Reset ()
end subroutine

public function long RowCount ()
end function

public function long DeletedCount ()
end function

public function long FilteredCount ()
end function

public function string GetItemString (long al_row, string as_col)
end function

public function decimal GetItemNumber (long al_row, string as_col)
end function

public function date GetItemDate (long al_row, string as_col)
end function

public function integer SetItem (long al_row, string as_col, any a_value)
end function

public function long GetRow ()
end function

public function integer SetRow (long al_row)
end function

public function integer SetColumn (string as_col)
end function

public function integer SetSort (string as_sort)
end function

public function integer Filter (string as_filter)
end function

public function long Find (string as_expr, long al_start, long al_end)
end function

public function integer SetRowFocusIndicator (any a_obj)
end function

public function integer InsertRow (long al_row)
end function

public function integer DeleteRow (long al_row)
end function

public function integer ModifiedCount ()
end function

public function integer GetColumnIndex (string as_col)
end function

public function string GetSQLSelect ()
end function

public function integer SetSQLSelect (string as_sql)
end function

public function integer ScrollToRow (long al_row)
end function

public function integer ShareData (any a_target)
end function

public function integer ShareDataOff ()
end function

public function integer ImportFile (string as_file, long al_startrow, long al_endrow, long al_startcol, long al_endcol)
end function

public function integer SaveAsAscii (string as_file, long al_startrow, long al_endrow)
end function

public function string Describe (string as_expr)
end function

public function integer Modify (string as_expr)
end function
