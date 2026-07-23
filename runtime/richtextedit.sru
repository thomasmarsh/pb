HA$PBExportHeader$richtextedit.sru

global type richtextedit from dragobject
end type

type variables
integer Accelerator
string AccessibleDescription
string AccessibleName
accessiblerole AccessibleRole
long BackColor
boolean Border
borderstyle BorderStyle
long BottomMargin
boolean BringToTop
powerobject ClassDefinition
boolean ControlCharsVisible
boolean DisplayOnly
string DocumentName
boolean DragAuto
string DragIcon
boolean Enabled
string FaceName
fontcharset FontCharSet
fontfamily FontFamily
fontpitch FontPitch
boolean HeaderFooter
integer Height
boolean HScrollBar
integer ImeMode
long InputFieldBackColor
boolean InputFieldNamesVisible
boolean InputFieldsVisible
boolean Italic
long LeftMargin
boolean Modified
long PaperHeight
paperorientation PaperOrientation
long PaperWidth
boolean PicturesAsFrame
string Pointer
boolean PopMenu
boolean Resizable
long RightMargin
boolean RightToLeft
boolean RulerBar
long SelectedStartPos
long SelectedTextLength
boolean StatusBar
integer TabOrder
string Tag
integer TextSize
boolean ToolBar
long TopMargin
boolean Underline
boolean Visible
boolean VScrollBar
integer Weight
integer Width
boolean WordWrap
integer X
integer Y
end variables

public function boolean canredo ()
end function

public function boolean canundo ()
end function

public function string classname ()
end function

public function long clear (boolean gridflag)
end function

public function long clearall ()
end function

public function long copy ()
end function

public function string copyrtf (boolean selected, any band)
end function

public function long cut ()
end function

public function integer datasource (datawindow dwsource)
end function

public function integer drag (dragmodes m)
end function

public function integer find (string searchtext, boolean forward, boolean insensitive, boolean wholeword, boolean cursor)
end function

public function integer findnext ()
end function

public function boolean formcheckboxgetchecked (integer fieldID)
end function

public function integer formcheckboxinsert (boolean checked, char checkedChar, char uncheckedChar)
end function

public function integer formcheckboxsetchecked (integer fieldID, boolean checked)
end function

public function integer formcomboboxgetitems (integer fieldID, ref string items[])
end function

public function integer formcomboboxinsert ()
end function

public function integer formcomboboxsetitems (integer fieldID, string items[])
end function

public function date formdatefieldgetdate (integer fieldID)
end function

public function string formdatefieldgetformat (integer fieldID)
end function

public function integer formdatefieldinsert (date fieldDate, boolean showDateControl, string format, integer emptyWidth)
end function

public function integer formdatefieldsetdate (integer fieldID, date fieldDate)
end function

public function integer formdatefieldsetformat (integer fieldID, string format)
end function

public function integer formfielddelete (integer fieldID, boolean deleteTotal)
end function

public function integer formfieldgetcurrent ()
end function

public function integer formfieldgetdeletable ()
end function

public function integer formfieldgetemptywidth (integer fieldID)
end function

public function integer formfieldgetend (integer fieldID)
end function

public function integer formfieldgetstart (integer fieldID)
end function

public function integer formfieldgettext (integer fieldID)
end function

public function integer formfieldnext (integer fieldID, string formFieldTypes[])
end function

public function integer formfieldsetcurrent (integer fieldID)
end function

public function integer formfieldsetdeletable ()
end function

public function integer formfieldsetemptywidth (integer fieldID, integer width)
end function

public function integer formfieldsettext (integer fieldID, string text)
end function

public function integer formtextfieldinsert (string text, integer emptyWidth)
end function

public function any getalignment ()
end function

public function integer getcontextservice (string servicename, powerobject servicereference)
end function

public function long getparagraphsetting (any whichsetting)
end function

public function powerobject getparent ()
end function

public function any getspacing ()
end function

public function long gettextcolor ()
end function

public function string gettextfontname ()
end function

public function integer gettextfontsize ()
end function

public function boolean gettextstyle (any textstyle)
end function

public function integer hide ()
end function

public function integer inputfieldchangedata (string inputfieldname, string inputfieldvalue)
end function

public function string inputfieldcurrentname ()
end function

public function integer inputfielddeletecurrent ()
end function

public function string inputfieldgetdata (string inputfieldname)
end function

public function integer inputfieldinsert (string inputfieldname)
end function

public function string inputfieldlocate (any location, string inputfieldname)
end function

public function integer insertdocument (string filename, boolean clearflag, any filetype, any encoding)
end function

public function integer insertpicture (string filename, integer format)
end function

public function boolean ispreview ()
end function

public function integer linecount ()
end function

public function integer linelength ()
end function

public function integer move (any x, any y)
end function

public function integer pagecount ()
end function

public function integer paste ()
end function

public function long pastertf (string richtextstring, any band)
end function

public function integer pastespecial ()
end function

public function integer pointerx ()
end function

public function integer pointery ()
end function

public function integer position (except RichTextEdit)
end function

public function boolean postevent (string event, long word, any long)
end function

public function integer preview (boolean previewsetting)
end function

public function integer print ()
end function

public function integer printex (boolean canceldialog)
end function

public function integer redo ()
end function

public function integer removetab (integer tabcurrent)
end function

public function integer replacetext (string string)
end function

public function integer resize (any width, any height)
end function

public function integer savedocument (string filename, any filetype, character encoding)
end function

public function integer savedocumentaspdf (string filePathName, string standard, string userPassword, string masterPassword, string restrictions)
end function

public function integer scroll (long number)
end function

public function integer scrollnextpage ()
end function

public function long scrollnextrow ()
end function

public function long scrollpriorpage ()
end function

public function long scrollpriorrow ()
end function

public function long scrolltorow (datawindow row)
end function

public function integer selectedcolumn ()
end function

public function long selectedlength ()
end function

public function long selectedline ()
end function

public function long selectedpage ()
end function

public function integer selectedstart ()
end function

public function string selectedtext ()
end function

public function long selecttext ()
end function

public function integer selecttextall (any band)
end function

public function integer selecttextline ()
end function

public function integer selecttextword ()
end function

public function integer setalignment (any align)
end function

public function integer setfocus ()
end function

public function integer setparagraphsetting (any whichsetting, long value)
end function

public function integer setposition ()
end function

public function integer setredraw ()
end function

public function integer setspacing (any spacing)
end function

public function integer settab (integer tabcurrent, integer tabtype, integer tabpos)
end function

public function integer settextcolor (long colornumber)
end function

public function integer settextfontname (string fontname)
end function

public function integer settextfontsize (integer fontsize)
end function

public function integer settextstyle (boolean bold, boolean underline, boolean subscript, boolean superscript, boolean italic, boolean strikeout)
end function

public function integer show ()
end function

public function integer showheadfoot (boolean editheadfoot, boolean headerfooter)
end function

public function long tableatinputpos ()
end function

public function boolean tablecanchangeattr ()
end function

public function boolean tablecellselect (long tableID, long row, long column)
end function

public function long tablecellstart (long tableID, long row, long column)
end function

public function long tablecolumnatinputpos ()
end function

public function boolean tabledelete (long tableID)
end function

public function boolean tabledeletecolumn (long tableID, long column)
end function

public function boolean tabledeletecolumns ()
end function

public function boolean tabledeleterow (long tableID, long row)
end function

public function boolean tabledeleterows ()
end function

public function long tablefromselection (ref long row, ref long column)
end function

public function long tablegetcellbackcolor (long tableID, long row, long column)
end function

public function long tablegetcellbordercolor (long tableID, long row, long column, integer borderType)
end function

public function integer tablegetcellborderwidth (long tableID, long row, long column, integer borderType)
end function

public function boolean tablegetcellheader (long tableID, long row, long column)
end function

public function integer tablegetcellheight (long tableID, long row, long column)
end function

public function integer tablegetcellhorizontalext ()
end function

public function integer tablegetcellhorizontalpos (long tableID, long row, long column)
end function

public function string tablegetcelllength (long tableID, long row, long column)
end function

public function string tablegetcellnumberformat (long tableID, long row, long column)
end function

public function string tablegetcelltext (long tableID, long row, long column)
end function

public function integer tablegetcelltextgap (long tableID, long row, long column, integer gapType)
end function

public function integer tablegetcelltexttype (long tableID, long row, long column)
end function

public function integer tablegetcellvertalign (long tableID, long row, long column)
end function

public function long tablegetcolumncount (long tableID)
end function

public function long tablegetrowcount (long tableID)
end function

public function long tableinsert (long rows, long columns)
end function

public function boolean tableinsertcolumn (integer position)
end function

public function long tableinsertdialog ()
end function

public function boolean tableinsertrow (integer position)
end function

public function boolean tableinsertrows (integer position)
end function

public function boolean tablemergecells ()
end function

public function integer tablenext (integer enumerationNumber, ref integer tableID)
end function

public function boolean tablepropertiesdialog (integer activeTab)
end function

public function long tablerowatinputpos ()
end function

public function boolean tablesetcellbackcolor (long tableID, long row, long column, long color)
end function

public function boolean tablesetcellbordercolor (long tableID, long row, long column, long color)
end function

public function boolean tablesetcellborderwidth (long tableID, long row, long column, integer width)
end function

public function boolean tablesetcellheader (long tableID, long row, long column, boolean bHeader)
end function

public function boolean tablesetcellheight (long tableID, long row, long column, integer height)
end function

public function boolean tablesetcellhorizontalext (long tableID, long row, long column, integer horizontalExt)
end function

public function boolean tablesetcellhorizontalpos (long tableID, long row, long column, integer horizontalPos)
end function

public function boolean tablesetcellnumberformat (long tableID, long row, long column, string format)
end function

public function boolean tablesetcelltext (long tableID, long row, long column, string text)
end function

public function boolean tablesetcelltextgap (long tableID, long row, long column, integer gap)
end function

public function boolean tablesetcelltexttype (long tableID, long row, long column, integer textType)
end function

public function boolean tablesetcellvertalign (long tableID, long row, long column, integer align)
end function

public function boolean tablesplitcells ()
end function

public function integer targetdelete (long id)
end function

public function string targetgetname (long id)
end function

public function integer targetgoto (long id)
end function

public function long targetinsert ()
end function

public function long targetnext (long id)
end function

public function integer targetsetname ()
end function

public function string textfieldgettext (integer id)
end function

public function string textfieldgettype (integer id)
end function

public function integer textfieldgettypedata (integer id, ref string data)
end function

public function integer textfieldinsert (string text)
end function

public function integer textfieldsettext (integer id, string text)
end function

public function integer textfieldsettypeanddata ()
end function

public function long textframegetbackcolor (integer textFrameID)
end function

public function integer textframegetborderwidth (integer textFrameID)
end function

public function integer textframegetinternalmargin (integer textFrameID, integer index)
end function

public function boolean textframegetmarkerlines (integer textFrameID)
end function

public function string textframegettext (integer textFrameID)
end function

public function integer textframeinsert (long textPos, integer alignment, long posX, long posY, integer width, integer height, integer textFlow, integer distanceL, integer distanceT, integer distanceR, integer distanceB)
end function

public function integer textframeinsertaschar (long textPos, integer width, integer height)
end function

public function integer textframeinsertfixed (long pageNo, long posX, long PosY, integer width, integer height, integer textFlow, integer distanceL, integer distanceT, integer distanceR, integer distanceB)
end function

public function boolean textframeselect (integer textFrameID)
end function

public function boolean textframesetbackcolor (integer textFrameID, long color)
end function

public function boolean textframesetborderwidth (integer textFrameID, integer width)
end function

public function boolean textframesetinternalmargin (integer textFrameID, integer index, integer margin)
end function

public function boolean textframesetmarkerlines (integer textFrameID, boolean markerLines)
end function

public function boolean textframesettext (integer textFrameID, string text)
end function

public function string textline ()
end function

public function integer triggerevent (string event, long word, long long)
end function

public function any typeof ()
end function

public function integer undo ()
end function

on richtextedit.constructor
end on

on richtextedit.destructor
end on

on richtextedit.doubleclicked
end on

on richtextedit.dragdrop
end on

on richtextedit.dragenter
end on

on richtextedit.dragleave
end on

on richtextedit.dragwithin
end on

on richtextedit.fileexists
end on

on richtextedit.getfocus
end on

on richtextedit.inputfieldselected
end on

on richtextedit.key
end on

on richtextedit.losefocus
end on

on richtextedit.modified
end on

on richtextedit.mousedown
end on

on richtextedit.mousemove
end on

on richtextedit.mouseup
end on

on richtextedit.pictureselected
end on

on richtextedit.printfooter
end on

on richtextedit.printheader
end on

on richtextedit.rbuttondown
end on

on richtextedit.rbuttonup
end on
