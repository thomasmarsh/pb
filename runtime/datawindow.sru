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

public function integer accepttext ()
end function

public function boolean canundo ()
end function

public function integer categorycount (datawindow graphcontrol)
end function

public function string categoryname (datawindow graphcontrol, any categorynumber)
end function

public function integer clear (boolean gridflag)
end function

public function integer clearvalues (string column)
end function

public function integer clipboard (any string)
end function

public function integer copy ()
end function

public function string copyrtf (boolean selected, any band)
end function

public function integer create ()
end function

public function integer crosstabdialog ()
end function

public function integer cut ()
end function

public function long datacount (datawindow graphcontrol, string seriesname)
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

public function integer drag (dragmodes m)
end function

public function integer expand (long row, long grouplevel)
end function

public function integer expandall (any itemhandle)
end function

public function integer expandallchildren (long row, long grouplevel)
end function

public function integer expandlevel (long grouplevel)
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

public function integer findcategory (datawindow graphcontrol, any categoryvalue)
end function

public function long findgroupchange (long row, integer level)
end function

public function integer findnext ()
end function

public function integer findrequired (dwbuffer dwbuffer, long row, integer colnbr, string colname, boolean updateonly)
end function

public function integer findseries (datawindow graphcontrol, string seriesname)
end function

public function integer generatehtmlform ()
end function

public function long generateresultset (resultset rsdest, dwbuffer dwbuffer)
end function

public function string getbandatpointer ()
end function

public function any getborderstyle (integer column)
end function

public function long getchanges (blob changeblob, blob cookie)
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

public function double getdata (datawindow graphcontrol, any seriesnumber, any datapoint, any datatype)
end function

public function integer getdatalabelling ()
end function

public function integer getdatapieexplode (datawindow graphcontrol, any series, any datapoint, integer percentage)
end function

public function integer getdatastyle (any graphcontrol, any seriesnumber, any datapointnumber, any colortype, any colorvariable)
end function

public function integer getdatatransparency (datawindow graphcontrol, any seriesnumber, any datapoint, integer transparency)
end function

public function integer getdatavalue (datawindow graphcontrol, any seriesnumber, any datapoint, double datavariable, any xory)
end function

public function any getdwobject ()
end function

public function string getformat (string column)
end function

public function long getfullstate (blob dwasblob)
end function

public function date getitemdate (char itempath)
end function

public function datetime getitemdatetime (char itempath)
end function

public function decimal getitemdecimal (long itemhandle)
end function

public function double getitemnumber (char itempath)
end function

public function any getitemstatus (long row, integer column, dwbuffer dwbuffer)
end function

public function string getitemstring (char itempath)
end function

public function time getitemtime (char itempath)
end function

public function string getmessagetext ()
end function

public function long getnextmodified (long row, dwbuffer dwbuffer)
end function

public function string getobjectatpointer ()
end function

public function long getrow ()
end function

public function long getrowfromrowid (long rowid, dwbuffer buffer)
end function

public function long getrowidfromrow (long rownumber, dwbuffer buffer)
end function

public function integer getselectedrow (long row)
end function

public function integer getserieslabelling (datawindow graphcontrol, string series, boolean value)
end function

public function integer getseriesstyle (any graphcontrol, any seriesname, any colortype, any colorvariable)
end function

public function integer getseriestransparency (datawindow graphcontrol, string series, integer transparency)
end function

public function string getsqlpreview ()
end function

public function string getsqlselect ()
end function

public function long getstatestatus (blob cookie)
end function

public function string gettext ()
end function

public function integer gettrans (transaction transaction)
end function

public function integer getupdatestatus (long row, dwbuffer dwbuffer)
end function

public function string getvalidate (string column)
end function

public function string getvalue (any d, any t)
end function

public function integer groupcalc ()
end function

public function long importclipboard (any importtype, any startrow, any endrow, any startcolumn)
end function

public function long importfile (any importtype, any filename, any startrow, any endrow, any startcolumn)
end function

public function long importjson (string data)
end function

public function long importjsonbykey (string json, string error, dwbuffer dwbuffer, long startrow, long endrow)
end function

public function long importrowfromjson (string json, long row, string error, dwbuffer dwbuffer)
end function

public function long importstring (any importtype, any string, any startrow, any endrow, any startcolumn)
end function

public function integer insertdocument (string filename, boolean clearflag, any filetype, any encoding)
end function

public function long insertrow (long row)
end function

public function boolean isselected (long row)
end function

public function integer linecount ()
end function

public function long modifiedcount ()
end function

public function string modify (string modstring)
end function

public function any objectatpointer (datawindow graphcontrol, integer seriesnumber, integer datapoint)
end function

public function integer oleactivate (long row, integer column, integer verb)
end function

public function integer paste ()
end function

public function long pastertf (string richtextstring, any band)
end function

public function integer pointerx ()
end function

public function integer pointery ()
end function

public function integer position (except richtextedit)
end function

public function integer printcancel (any printjobnumber)
end function

public function integer replacetext (string string)
end function

public function integer reselectrow (long row)
end function

public function integer reset ()
end function

public function integer resetdatacolors (datawindow graphcontrol, any seriesnumber, any datapointnumber)
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

public function integer saveas (any filename, any graphcontrol, any saveastype, any colheading, any encoding)
end function

public function long saveasascii (string filename, string separatorcharacter, string quotecharacter, string lineending, boolean retainnewlinechar)
end function

public function integer saveasformattedtext (string filename, encoding encoding, string separatorcharacter, string quotecharacter, string lineending, boolean retainnewlinechar)
end function

public function integer savedisplayeddataas (string filename, saveastype saveastype, encoding encoding)
end function

public function integer saveink (string name, long rownumber, blob blob)
end function

public function integer saveinkpic ()
end function

public function integer savenativepdftoblob (blob data)
end function

public function integer scroll (long number)
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

public function integer selectedlength ()
end function

public function integer selectedline ()
end function

public function integer selectedstart ()
end function

public function string selectedtext ()
end function

public function integer selectrow (long row, boolean select)
end function

public function integer selecttext (any start, any length)
end function

public function integer selecttextall (any band)
end function

public function integer selecttextline ()
end function

public function integer selecttextword ()
end function

public function integer seriescount (datawindow graphcontrol)
end function

public function string seriesname (datawindow graphcontrol, any seriesnumber)
end function

public function integer setactioncode (long code)
end function

public function long setchanges (blob changeblob, dwconflictresolution resolution)
end function

public function integer setcolumn (any index, any label, any alignment, any width)
end function

public function integer setdatalabelling ()
end function

public function integer setdatapieexplode (datawindow graphcontrol, any seriesnumber, any datapoint, any percentage)
end function

public function integer setdatastyle (any graphcontrol, any seriesnumber, any datapointnumber, any colortype, any color)
end function

public function integer setdatatransparency (datawindow graphcontrol, any seriesnumber, any datapoint, integer transparency)
end function

public function integer setdetailheight (long startrow, long endrow, long height)
end function

public function integer setfilter (string format)
end function

public function integer setfocus ()
end function

public function integer setformat (string column, string format)
end function

public function long setfullstate (blob dwasblob)
end function

public function integer sethtmlaction (string action, string context)
end function

public function integer setitem (any index, any column, any item)
end function

public function integer setitemstatus (long row, integer column, dwbuffer dwbuffer, dwitemstatus status)
end function

public function integer setposition (any position, any precedingobject)
end function

public function integer setredraw (any boolean)
end function

public function integer setrow (long row)
end function

public function integer setrowfocusindicator (rowfocusind focusindicator, integer xlocation, integer ylocation)
end function

public function integer setserieslabelling (datawindow graphcontrol, string series, any value)
end function

public function integer setseriesstyle (any graphcontrol, any seriesname, any colortype, any color)
end function

public function integer setseriestransparency (datawindow graphcontrol, string series, integer transparency)
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

public function integer setvalue (any d, any t)
end function

public function integer setwsobject ()
end function

public function integer sharedata (datawindow dwsecondary)
end function

public function integer sharedataoff ()
end function

public function integer showheadfoot (boolean editheadfoot, boolean headerfooter)
end function

public function integer sort (any itemhandle, any sorttype)
end function

public function string textline ()
end function

public function any typeof ()
end function

public function integer undo ()
end function

public function integer update (boolean accept, boolean resetflag)
end function

public function integer SetBorderStyle (integer ai_style)
end function

public function integer Print ()
end function

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
