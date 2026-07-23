HA$PBExportHeader$datawindowchild.sru

global type datawindowchild from structure
end type

type variables
powerobject ClassDefinition
end variables

public function integer accepttext ()
end function

public function string classname ()
end function

public function string clearvalues (string column)
end function

public function integer crosstabdialog ()
end function

public function integer dbcancel ()
end function

public function long dberrorcode ()
end function

public function string dberrormessage ()
end function

public function long deletedcount ()
end function

public function integer deleterow (long row)
end function

public function string describe (string propertylist)
end function

public function integer expand (long row, long groupLevel)
end function

public function integer expandall (any itemhandle)
end function

public function integer expandallchildren (long row, long groupLevel)
end function

public function integer expandlevel (long groupLevel)
end function

public function string exportjson ()
end function

public function string exportrowasjson (long row, dwbuffer dwbuffer)
end function

public function integer filter ()
end function

public function integer filteredcount ()
end function

public function long find (string searchtext, boolean forward, boolean insensitive, boolean wholeword, boolean cursor)
end function

public function long findgroupchange (long row, integer level)
end function

public function string getbandatpointer ()
end function

public function any getborderstyle (integer column)
end function

public function long getchanges (ref blob changeblob, blob cookie)
end function

public function integer getchild ()
end function

public function integer getclickedcolumn ()
end function

public function long getclickedrow ()
end function

public function integer getcolumn (integer index, string label, any alignment, integer width)
end function

public function string getcolumnname ()
end function

public function integer getcontextservice (string servicename, powerobject servicereference)
end function

public function string getformat (string column)
end function

public function date getitemdate (char itempath)
end function

public function datetime getitemdatetime (char itempath)
end function

public function decimal getitemdecimal (long ItemHandle)
end function

public function double getitemnumber (char itempath)
end function

public function any getitemstatus (long row, integer column, dwbuffer dwbuffer)
end function

public function string getitemstring (char itempath)
end function

public function time getitemtime (char itempath)
end function

public function long getnextmodified (long row, dwbuffer dwbuffer)
end function

public function string getobjectatpointer ()
end function

public function powerobject getparent ()
end function

public function long getrow ()
end function

public function long getrowfromrowid (long rowid, dwbuffer buffer)
end function

public function long getrowidfromrow (long rownumber, dwbuffer buffer)
end function

public function integer getselectedrow (long row)
end function

public function string getsqlpreview ()
end function

public function string getsqlselect ()
end function

public function string gettext ()
end function

public function integer gettrans (transaction transaction)
end function

public function integer getupdatestatus (long row, dwbuffer dwbuffer)
end function

public function string getvalidate (string column)
end function

public function string getvalue ()
end function

public function integer groupcalc ()
end function

public function long importclipboard (any importtype, any startrow, any endrow, any startcolumn)
end function

public function long importfile ()
end function

public function long importjson (string data)
end function

public function long importjsonbykey (string json, string error, dwbuffer dwbuffer, long startrow, long endrow)
end function

public function long importrowfromjson (string json, long row, ref string error, dwbuffer dwbuffer)
end function

public function long importstring ()
end function

public function long insertrow (long row)
end function

public function boolean isselected (long row)
end function

public function long modifiedcount ()
end function

public function string modify (string modstring)
end function

public function integer oleactivate (long row, integer column, integer verb)
end function

public function integer reselectrow (long row)
end function

public function integer reset ()
end function

public function integer resettransobject ()
end function

public function integer resetupdate ()
end function

public function long retrieve (datawindow dwcontrol, string urlname, string data, any tokenrequest)
end function

public function long rowcount ()
end function

public function integer rowscopy (long startrow, long endrow, dwbuffer copybuffer, datawindow targetdw, long beforerow, dwbuffer targetbuffer)
end function

public function integer rowsdiscard (long startrow, long endrow, dwbuffer buffer)
end function

public function integer rowsmove (long startrow, long endrow, dwbuffer movebuffer, datawindow targetdw, long beforerow, dwbuffer targetbuffer)
end function

public function integer saveas ()
end function

public function integer savenativepdftoblob (blob data)
end function

public function long scrollnextpage ()
end function

public function long scrollnextrow ()
end function

public function long scrollpriorpage ()
end function

public function long scrollpriorrow ()
end function

public function integer scrolltorow (datawindow row)
end function

public function integer selectrow (long row, boolean select)
end function

public function integer setborderstyle (integer column, border borderstyle)
end function

public function long setchanges (blob changeblob, dwconflictresolution resolution)
end function

public function integer setcolumn (any index, any label, any alignment, any width)
end function

public function integer setdetailheight (long startrow, long endrow, long height)
end function

public function integer setfilter (string format)
end function

public function integer setformat (string column, string format)
end function

public function integer setitem ()
end function

public function integer setitemstatus (long row, integer column, dwbuffer dwbuffer, dwitemstatus status)
end function

public function integer setposition ()
end function

public function integer setredraw ()
end function

public function integer setrow (long row)
end function

public function integer setrowfocusindicator (rowfocusind focusindicator, integer xlocation, integer ylocation)
end function

public function integer setsort (string format)
end function

public function integer setsqlpreview (string sqlsyntax)
end function

public function integer setsqlselect (string statement)
end function

public function integer settaborder (integer column, integer tabnumber)
end function

public function integer settext (string text)
end function

public function integer settrans (transaction transaction)
end function

public function integer settransobject (transaction transaction)
end function

public function integer setvalidate (string column, string rule)
end function

public function integer setvalue ()
end function

public function integer setwsobject ()
end function

public function integer sharedata (datawindow dwsecondary)
end function

public function integer sharedataoff ()
end function

public function integer sort ()
end function

public function any typeof ()
end function

public function integer update (boolean accept, boolean resetflag)
end function

on datawindowchild.constructor
end on

on datawindowchild.destructor
end on
