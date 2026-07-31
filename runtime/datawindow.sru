HA$PBExportHeader$datawindow.sru

global type datawindow from dragobject
end type

type variables
integer x
integer y
integer width
integer height
boolean visible
boolean enabled
integer hscrollposition
integer vscrollposition
boolean hsplitscroll
string AccessibleDescription
string AccessibleName
accessiblerole AccessibleRole
boolean Border
borderstyle BorderStyle
boolean BringToTop
powerobject ClassDefinition
boolean ControlMenu
string DataObject
boolean DragAuto
string DragIcon
boolean HScrollBar
string Icon
boolean LiveScroll
boolean MaxBox
boolean MinBox
dwobject Object
boolean Resizable
boolean RightToLeft
integer TabOrder
string Tag
string Title
boolean TitleBar
boolean VScrollBar
end variables

// @effects WritesControlState
public function integer accepttext ()
end function

// @effects ReadsControlState
public function boolean canundo ()
end function

// @effects ReadsControlState
public function integer categorycount (datawindow graphcontrol)
end function

// @effects ReadsControlState
public function string categoryname (datawindow graphcontrol, any categorynumber)
end function

// @effects WritesControlState
public function integer clear (boolean gridflag)
end function

// @effects WritesControlState
public function integer clearvalues (string column)
end function

// @effects WritesControlState
public function integer clipboard (any string)
end function

// @effects ReadsControlState
public function integer copy ()
end function

// @effects ReadsControlState
public function string copyrtf (boolean selected, any band)
end function

// @effects WritesControlState
public function integer create ()
end function

// @effects WritesControlState
public function integer crosstabdialog ()
end function

// @effects WritesControlState
public function integer cut ()
end function

// @effects ReadsControlState
public function long datacount (datawindow graphcontrol, string seriesname)
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
public function integer drag (dragmodes m)
end function

// @effects WritesControlState
public function integer expand (long row, long grouplevel)
end function

// @effects WritesControlState
public function integer expandall (any itemhandle)
end function

// @effects WritesControlState
public function integer expandallchildren (long row, long grouplevel)
end function

// @effects WritesControlState
public function integer expandlevel (long grouplevel)
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
public function integer findcategory (datawindow graphcontrol, any categoryvalue)
end function

// @effects ReadsControlState
public function long findgroupchange (long row, integer level)
end function

// @effects ReadsControlState
public function integer findnext ()
end function

// @effects ReadsControlState
public function integer findrequired (dwbuffer dwbuffer, long row, integer colnbr, string colname, boolean updateonly)
end function

// @effects ReadsControlState
public function integer findseries (datawindow graphcontrol, string seriesname)
end function

// @effects ReadsControlState
public function integer generatehtmlform ()
end function

// @effects ReadsControlState
public function long generateresultset (resultset rsdest, dwbuffer dwbuffer)
end function

// @effects ReadsControlState
public function string getbandatpointer ()
end function

// @effects ReadsControlState
public function any getborderstyle (integer column)
end function

// @effects ReadsControlState
public function long getchanges (blob changeblob, blob cookie)
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
public function double getdata (datawindow graphcontrol, any seriesnumber, any datapoint, any datatype)
end function

// @effects ReadsControlState
public function integer getdatalabelling ()
end function

// @effects ReadsControlState
public function integer getdatapieexplode (datawindow graphcontrol, any series, any datapoint, integer percentage)
end function

// @effects ReadsControlState
public function integer getdatastyle (any graphcontrol, any seriesnumber, any datapointnumber, any colortype, any colorvariable)
end function

// @effects ReadsControlState
public function integer getdatatransparency (datawindow graphcontrol, any seriesnumber, any datapoint, integer transparency)
end function

// @effects ReadsControlState
public function integer getdatavalue (datawindow graphcontrol, any seriesnumber, any datapoint, double datavariable, any xory)
end function

// @effects ReadsControlState
public function any getdwobject ()
end function

// @effects ReadsControlState
public function string getformat (string column)
end function

// @effects ReadsControlState
public function long getfullstate (blob dwasblob)
end function

// @effects ReadsControlState
public function date getitemdate (char itempath)
end function

// @effects ReadsControlState
public function datetime getitemdatetime (char itempath)
end function

// @effects ReadsControlState
public function decimal getitemdecimal (long itemhandle)
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
public function string getmessagetext ()
end function

// @effects ReadsControlState
public function long getnextmodified (long row, dwbuffer dwbuffer)
end function

// @effects ReadsControlState
public function string getobjectatpointer ()
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
public function integer getserieslabelling (datawindow graphcontrol, string series, boolean value)
end function

// @effects ReadsControlState
public function integer getseriesstyle (any graphcontrol, any seriesname, any colortype, any colorvariable)
end function

// @effects ReadsControlState
public function integer getseriestransparency (datawindow graphcontrol, string series, integer transparency)
end function

// @effects ReadsControlState
public function string getsqlpreview ()
end function

// @effects ReadsControlState
public function string getsqlselect ()
end function

// @effects ReadsControlState
public function long getstatestatus (blob cookie)
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
public function string getvalue (any d, any t)
end function

// @effects WritesControlState
public function integer groupcalc ()
end function

// @effects WritesControlState
public function long importclipboard (any importtype, any startrow, any endrow, any startcolumn)
end function

// @effects WritesControlState
public function long importfile (any importtype, any filename, any startrow, any endrow, any startcolumn)
end function

// @effects WritesControlState
public function long importjson (string data)
end function

// @effects WritesControlState
public function long importjsonbykey (string json, string error, dwbuffer dwbuffer, long startrow, long endrow)
end function

// @effects WritesControlState
public function long importrowfromjson (string json, long row, string error, dwbuffer dwbuffer)
end function

// @effects WritesControlState
public function long importstring (any importtype, any string, any startrow, any endrow, any startcolumn)
end function

// @effects WritesControlState
public function integer insertdocument (string filename, boolean clearflag, any filetype, any encoding)
end function

// @effects WritesControlState
public function long insertrow (long row)
end function

// @effects ReadsControlState
public function boolean isselected (long row)
end function

// @effects ReadsControlState
public function integer linecount ()
end function

// @effects ReadsControlState
public function long modifiedcount ()
end function

// @effects WritesControlState
public function string modify (string modstring)
end function

// @effects ReadsControlState
public function any objectatpointer (datawindow graphcontrol, integer seriesnumber, integer datapoint)
end function

// @effects WritesControlState
public function integer oleactivate (long row, integer column, integer verb)
end function

// @effects WritesControlState
public function integer paste ()
end function

// @effects WritesControlState
public function long pastertf (string richtextstring, any band)
end function

// @effects ReadsControlState
public function integer pointerx ()
end function

// @effects ReadsControlState
public function integer pointery ()
end function

// @effects ReadsControlState
public function integer position (except richtextedit)
end function

// @effects Suspends
public function integer printcancel (any printjobnumber)
end function

// @effects WritesControlState
public function integer replacetext (string string)
end function

// @effects WritesControlState
public function integer reselectrow (long row)
end function

// @effects WritesControlState
public function integer reset ()
end function

// @effects WritesControlState
public function integer resetdatacolors (datawindow graphcontrol, any seriesnumber, any datapointnumber)
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
public function integer saveas (any filename, any graphcontrol, any saveastype, any colheading, any encoding)
end function

// @effects ReadsControlState
public function long saveasascii (string filename, string separatorcharacter, string quotecharacter, string lineending, boolean retainnewlinechar)
end function

// @effects ReadsControlState
public function integer saveasformattedtext (string filename, encoding encoding, string separatorcharacter, string quotecharacter, string lineending, boolean retainnewlinechar)
end function

// @effects ReadsControlState
public function integer savedisplayeddataas (string filename, saveastype saveastype, encoding encoding)
end function

// @effects ReadsControlState
public function integer saveink (string name, long rownumber, blob blob)
end function

// @effects ReadsControlState
public function integer saveinkpic ()
end function

// @effects ReadsControlState
public function integer savenativepdftoblob (blob data)
end function

// @effects WritesControlState
public function integer scroll (long number)
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

// @effects ReadsControlState
public function integer selectedlength ()
end function

// @effects ReadsControlState
public function integer selectedline ()
end function

// @effects ReadsControlState
public function integer selectedstart ()
end function

// @effects ReadsControlState
public function string selectedtext ()
end function

// @effects WritesControlState
public function integer selectrow (long row, boolean select)
end function

// @effects WritesControlState
public function integer selecttext (any start, any length)
end function

// @effects WritesControlState
public function integer selecttextall (any band)
end function

// @effects WritesControlState
public function integer selecttextline ()
end function

// @effects WritesControlState
public function integer selecttextword ()
end function

// @effects ReadsControlState
public function integer seriescount (datawindow graphcontrol)
end function

// @effects ReadsControlState
public function string seriesname (datawindow graphcontrol, any seriesnumber)
end function

// @effects WritesControlState
public function integer setactioncode (long code)
end function

// @effects WritesControlState
public function long setchanges (blob changeblob, dwconflictresolution resolution)
end function

// @effects WritesControlState
public function integer setcolumn (any index, any label, any alignment, any width)
end function

// @effects WritesControlState
public function integer setdatalabelling ()
end function

// @effects WritesControlState
public function integer setdatapieexplode (datawindow graphcontrol, any seriesnumber, any datapoint, any percentage)
end function

// @effects WritesControlState
public function integer setdatastyle (any graphcontrol, any seriesnumber, any datapointnumber, any colortype, any color)
end function

// @effects WritesControlState
public function integer setdatatransparency (datawindow graphcontrol, any seriesnumber, any datapoint, integer transparency)
end function

// @effects WritesControlState
public function integer setdetailheight (long startrow, long endrow, long height)
end function

// @effects WritesControlState
public function integer setfilter (string format)
end function

// @effects WritesControlState
public function integer setfocus ()
end function

// @effects WritesControlState
public function integer setformat (string column, string format)
end function

// @effects WritesControlState
public function long setfullstate (blob dwasblob)
end function

// @effects WritesControlState
public function integer sethtmlaction (string action, string context)
end function

// @effects WritesControlState
public function integer setitem (any index, any column, any item)
end function

// @effects WritesControlState
public function integer setitemstatus (long row, integer column, dwbuffer dwbuffer, dwitemstatus status)
end function

// @effects WritesControlState
public function integer setposition (any position, any precedingobject)
end function

// @effects WritesControlState
public function integer setredraw (any boolean)
end function

// @effects WritesControlState
public function integer setrow (long row)
end function

// @effects WritesControlState
public function integer setrowfocusindicator (rowfocusind focusindicator, integer xlocation, integer ylocation)
end function

// @effects WritesControlState
public function integer setserieslabelling (datawindow graphcontrol, string series, any value)
end function

// @effects WritesControlState
public function integer setseriesstyle (any graphcontrol, any seriesname, any colortype, any color)
end function

// @effects WritesControlState
public function integer setseriestransparency (datawindow graphcontrol, string series, integer transparency)
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
public function integer setvalue (any d, any t)
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
public function integer showheadfoot (boolean editheadfoot, boolean headerfooter)
end function

// @effects WritesControlState
public function integer sort (any itemhandle, any sorttype)
end function

// @effects ReadsControlState
public function string textline ()
end function

// @effects (pure)
public function any typeof ()
end function

// @effects WritesControlState
public function integer undo ()
end function

// @effects Suspends, WritesDb
public function integer update (boolean accept, boolean resetflag)
end function

// @effects WritesControlState
public function integer SetBorderStyle (integer ai_style)
end function

// @effects Suspends, WritesUi
public function integer Print ()
end function

// @effects ReadsControlState
public function string Object (string as_expr)
end function

on datawindow.itemchanged
end on

on datawindow.retrieveend
end on

on datawindow.rowfocuschanging
end on

on datawindow.buttonclicked
end on

on datawindow.clicked
end on

on datawindow.doubleclicked
end on
