HA$PBExportHeader$datawindowchild.sru

global type datawindowchild from structure
end type

type variables
powerobject ClassDefinition
end variables

// @effects WritesControlState
public function integer accepttext ()
end function

// @effects (pure)
public function string classname ()
end function

// @effects WritesControlState
public function string clearvalues (string column)
end function

// @effects WritesControlState
public function integer crosstabdialog ()
end function

// @effects Suspends
public function integer dbcancel ()
end function

// @effects ReadsControlState
public function long dberrorcode ()
end function

// @effects ReadsControlState
public function string dberrormessage ()
end function

// @effects ReadsControlState
public function long deletedcount ()
end function

// @effects WritesControlState
public function integer deleterow (long row)
end function

// @effects ReadsControlState
public function string describe (string propertylist)
end function

// @effects WritesControlState
public function integer expand (long row, long groupLevel)
end function

// @effects WritesControlState
public function integer expandall (any itemhandle)
end function

// @effects WritesControlState
public function integer expandallchildren (long row, long groupLevel)
end function

// @effects WritesControlState
public function integer expandlevel (long groupLevel)
end function

// @effects ReadsControlState
public function string exportjson ()
end function

// @effects ReadsControlState
public function string exportrowasjson (long row, dwbuffer dwbuffer)
end function

// @effects WritesControlState
public function integer filter ()
end function

// @effects ReadsControlState
public function integer filteredcount ()
end function

// @effects ReadsControlState
public function long find (string searchtext, boolean forward, boolean insensitive, boolean wholeword, boolean cursor)
end function

// @effects ReadsControlState
public function long findgroupchange (long row, integer level)
end function

// @effects ReadsControlState
public function string getbandatpointer ()
end function

// @effects ReadsControlState
public function any getborderstyle (integer column)
end function

// @effects ReadsControlState
public function long getchanges (ref blob changeblob, blob cookie)
end function

// @effects ReadsControlState
public function integer getchild ()
end function

// @effects ReadsControlState
public function integer getclickedcolumn ()
end function

// @effects ReadsControlState
public function long getclickedrow ()
end function

// @effects ReadsControlState
public function integer getcolumn (integer index, string label, any alignment, integer width)
end function

// @effects ReadsControlState
public function string getcolumnname ()
end function

// @effects ReadsControlState
public function integer getcontextservice (string servicename, powerobject servicereference)
end function

// @effects ReadsControlState
public function string getformat (string column)
end function

// @effects ReadsControlState
public function date getitemdate (char itempath)
end function

// @effects ReadsControlState
public function datetime getitemdatetime (char itempath)
end function

// @effects ReadsControlState
public function decimal getitemdecimal (long ItemHandle)
end function

// @effects ReadsControlState
public function double getitemnumber (char itempath)
end function

// @effects ReadsControlState
public function any getitemstatus (long row, integer column, dwbuffer dwbuffer)
end function

// @effects ReadsControlState
public function string getitemstring (char itempath)
end function

// @effects ReadsControlState
public function time getitemtime (char itempath)
end function

// @effects ReadsControlState
public function long getnextmodified (long row, dwbuffer dwbuffer)
end function

// @effects ReadsControlState
public function string getobjectatpointer ()
end function

// @effects ReadsControlState
public function powerobject getparent ()
end function

// @effects ReadsControlState
public function long getrow ()
end function

// @effects ReadsControlState
public function long getrowfromrowid (long rowid, dwbuffer buffer)
end function

// @effects ReadsControlState
public function long getrowidfromrow (long rownumber, dwbuffer buffer)
end function

// @effects ReadsControlState
public function integer getselectedrow (long row)
end function

// @effects ReadsControlState
public function string getsqlpreview ()
end function

// @effects ReadsControlState
public function string getsqlselect ()
end function

// @effects ReadsControlState
public function string gettext ()
end function

// @effects ReadsControlState
public function integer gettrans (transaction transaction)
end function

// @effects ReadsControlState
public function integer getupdatestatus (long row, dwbuffer dwbuffer)
end function

// @effects ReadsControlState
public function string getvalidate (string column)
end function

// @effects ReadsControlState
public function string getvalue ()
end function

// @effects WritesControlState
public function integer groupcalc ()
end function

// @effects WritesControlState
public function long importclipboard (any importtype, any startrow, any endrow, any startcolumn)
end function

// @effects WritesControlState
public function long importfile ()
end function

// @effects WritesControlState
public function long importjson (string data)
end function

// @effects WritesControlState
public function long importjsonbykey (string json, string error, dwbuffer dwbuffer, long startrow, long endrow)
end function

// @effects WritesControlState
public function long importrowfromjson (string json, long row, ref string error, dwbuffer dwbuffer)
end function

// @effects WritesControlState
public function long importstring ()
end function

// @effects WritesControlState
public function long insertrow (long row)
end function

// @effects ReadsControlState
public function boolean isselected (long row)
end function

// @effects ReadsControlState
public function long modifiedcount ()
end function

// @effects WritesControlState
public function string modify (string modstring)
end function

// @effects WritesControlState
public function integer oleactivate (long row, integer column, integer verb)
end function

// @effects WritesControlState
public function integer reselectrow (long row)
end function

// @effects WritesControlState
public function integer reset ()
end function

// @effects WritesControlState
public function integer resettransobject ()
end function

// @effects WritesControlState
public function integer resetupdate ()
end function

// @effects Suspends, ReadsDb
public function long retrieve (datawindow dwcontrol, string urlname, string data, any tokenrequest)
end function

// @effects ReadsControlState
public function long rowcount ()
end function

// @effects WritesControlState
public function integer rowscopy (long startrow, long endrow, dwbuffer copybuffer, datawindow targetdw, long beforerow, dwbuffer targetbuffer)
end function

// @effects WritesControlState
public function integer rowsdiscard (long startrow, long endrow, dwbuffer buffer)
end function

// @effects WritesControlState
public function integer rowsmove (long startrow, long endrow, dwbuffer movebuffer, datawindow targetdw, long beforerow, dwbuffer targetbuffer)
end function

// @effects ReadsControlState
public function integer saveas ()
end function

// @effects ReadsControlState
public function integer savenativepdftoblob (blob data)
end function

// @effects WritesControlState
public function long scrollnextpage ()
end function

// @effects WritesControlState
public function long scrollnextrow ()
end function

// @effects WritesControlState
public function long scrollpriorpage ()
end function

// @effects WritesControlState
public function long scrollpriorrow ()
end function

// @effects WritesControlState
public function integer scrolltorow (datawindow row)
end function

// @effects WritesControlState
public function integer selectrow (long row, boolean select)
end function

// @effects WritesControlState
public function integer setborderstyle (integer column, border borderstyle)
end function

// @effects WritesControlState
public function long setchanges (blob changeblob, dwconflictresolution resolution)
end function

// @effects WritesControlState
public function integer setcolumn (any index, any label, any alignment, any width)
end function

// @effects WritesControlState
public function integer setdetailheight (long startrow, long endrow, long height)
end function

// @effects WritesControlState
public function integer setfilter (string format)
end function

// @effects WritesControlState
public function integer setformat (string column, string format)
end function

// @effects WritesControlState
public function integer setitem ()
end function

// @effects WritesControlState
public function integer setitemstatus (long row, integer column, dwbuffer dwbuffer, dwitemstatus status)
end function

// @effects WritesControlState
public function integer setposition ()
end function

// @effects WritesControlState
public function integer setredraw ()
end function

// @effects WritesControlState
public function integer setrow (long row)
end function

// @effects WritesControlState
public function integer setrowfocusindicator (rowfocusind focusindicator, integer xlocation, integer ylocation)
end function

// @effects WritesControlState
public function integer setsort (string format)
end function

// @effects WritesControlState
public function integer setsqlpreview (string sqlsyntax)
end function

// @effects WritesControlState
public function integer setsqlselect (string statement)
end function

// @effects WritesControlState
public function integer settaborder (integer column, integer tabnumber)
end function

// @effects WritesControlState
public function integer settext (string text)
end function

// @effects WritesControlState
public function integer settrans (transaction transaction)
end function

// @effects WritesControlState
public function integer settransobject (transaction transaction)
end function

// @effects WritesControlState
public function integer setvalidate (string column, string rule)
end function

// @effects WritesControlState
public function integer setvalue ()
end function

// @effects WritesControlState
public function integer setwsobject ()
end function

// @effects WritesControlState
public function integer sharedata (datawindow dwsecondary)
end function

// @effects WritesControlState
public function integer sharedataoff ()
end function

// @effects WritesControlState
public function integer sort ()
end function

// @effects (pure)
public function any typeof ()
end function

// @effects Suspends, WritesDb
public function integer update (boolean accept, boolean resetflag)
end function

on datawindowchild.constructor
end on

on datawindowchild.destructor
end on
