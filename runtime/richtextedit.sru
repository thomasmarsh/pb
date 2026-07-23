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

public function long clear ()
end function

public function long clearall ()
end function

public function long copy ()
end function

public function string copyrtf ()
end function

public function long cut ()
end function

public function integer datasource ()
end function

public function integer drag ()
end function

public function integer find ()
end function

public function integer findnext ()
end function

public function boolean formcheckboxgetchecked ()
end function

public function integer formcheckboxinsert ()
end function

public function integer formcheckboxsetchecked ()
end function

public function integer formcomboboxgetitems ()
end function

public function integer formcomboboxinsert ()
end function

public function integer formcomboboxsetitems ()
end function

public function date formdatefieldgetdate ()
end function

public function string formdatefieldgetformat ()
end function

public function integer formdatefieldinsert ()
end function

public function integer formdatefieldsetdate ()
end function

public function integer formdatefieldsetformat ()
end function

public function integer formfielddelete ()
end function

public function integer formfieldgetcurrent ()
end function

public function integer formfieldgetdeletable ()
end function

public function integer formfieldgetemptywidth ()
end function

public function integer formfieldgetend ()
end function

public function integer formfieldgetstart ()
end function

public function integer formfieldgettext ()
end function

public function integer formfieldnext ()
end function

public function integer formfieldsetcurrent ()
end function

public function integer formfieldsetdeletable ()
end function

public function integer formfieldsetemptywidth ()
end function

public function integer formfieldsettext ()
end function

public function integer formtextfieldinsert ()
end function

public function any getalignment ()
end function

public function integer getcontextservice ()
end function

public function long getparagraphsetting ()
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

public function boolean gettextstyle ()
end function

public function integer hide ()
end function

public function integer inputfieldchangedata ()
end function

public function string inputfieldcurrentname ()
end function

public function integer inputfielddeletecurrent ()
end function

public function string inputfieldgetdata ()
end function

public function integer inputfieldinsert ()
end function

public function string inputfieldlocate ()
end function

public function integer insertdocument ()
end function

public function integer insertpicture ()
end function

public function boolean ispreview ()
end function

public function integer linecount ()
end function

public function integer linelength ()
end function

public function integer move ()
end function

public function integer pagecount ()
end function

public function integer paste ()
end function

public function long pastertf ()
end function

public function integer pastespecial ()
end function

public function integer pointerx ()
end function

public function integer pointery ()
end function

public function integer position ()
end function

public function boolean postevent ()
end function

public function integer preview ()
end function

public function integer print ()
end function

public function integer printex ()
end function

public function integer redo ()
end function

public function integer removetab ()
end function

public function integer replacetext ()
end function

public function integer resize ()
end function

public function integer savedocument ()
end function

public function integer savedocumentaspdf ()
end function

public function integer scroll ()
end function

public function integer scrollnextpage ()
end function

public function long scrollnextrow ()
end function

public function long scrollpriorpage ()
end function

public function long scrollpriorrow ()
end function

public function long scrolltorow ()
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

public function integer selecttextall ()
end function

public function integer selecttextline ()
end function

public function integer selecttextword ()
end function

public function integer setalignment ()
end function

public function integer setfocus ()
end function

public function integer setparagraphsetting ()
end function

public function integer setposition ()
end function

public function integer setredraw ()
end function

public function integer setspacing ()
end function

public function integer settab ()
end function

public function integer settextcolor ()
end function

public function integer settextfontname ()
end function

public function integer settextfontsize ()
end function

public function integer settextstyle ()
end function

public function integer show ()
end function

public function integer showheadfoot ()
end function

public function long tableatinputpos ()
end function

public function boolean tablecanchangeattr ()
end function

public function boolean tablecellselect ()
end function

public function long tablecellstart ()
end function

public function long tablecolumnatinputpos ()
end function

public function boolean tabledelete ()
end function

public function boolean tabledeletecolumn ()
end function

public function boolean tabledeletecolumns ()
end function

public function boolean tabledeleterow ()
end function

public function boolean tabledeleterows ()
end function

public function long tablefromselection ()
end function

public function long tablegetcellbackcolor ()
end function

public function long tablegetcellbordercolor ()
end function

public function integer tablegetcellborderwidth ()
end function

public function boolean tablegetcellheader ()
end function

public function integer tablegetcellheight ()
end function

public function integer tablegetcellhorizontalext ()
end function

public function integer tablegetcellhorizontalpos ()
end function

public function string tablegetcelllength ()
end function

public function string tablegetcellnumberformat ()
end function

public function string tablegetcelltext ()
end function

public function integer tablegetcelltextgap ()
end function

public function integer tablegetcelltexttype ()
end function

public function integer tablegetcellvertalign ()
end function

public function long tablegetcolumncount ()
end function

public function long tablegetrowcount ()
end function

public function long tableinsert ()
end function

public function boolean tableinsertcolumn ()
end function

public function long tableinsertdialog ()
end function

public function boolean tableinsertrow ()
end function

public function boolean tableinsertrows ()
end function

public function boolean tablemergecells ()
end function

public function integer tablenext ()
end function

public function boolean tablepropertiesdialog ()
end function

public function long tablerowatinputpos ()
end function

public function boolean tablesetcellbackcolor ()
end function

public function boolean tablesetcellbordercolor ()
end function

public function boolean tablesetcellborderwidth ()
end function

public function boolean tablesetcellheader ()
end function

public function boolean tablesetcellheight ()
end function

public function boolean tablesetcellhorizontalext ()
end function

public function boolean tablesetcellhorizontalpos ()
end function

public function boolean tablesetcellnumberformat ()
end function

public function boolean tablesetcelltext ()
end function

public function boolean tablesetcelltextgap ()
end function

public function boolean tablesetcelltexttype ()
end function

public function boolean tablesetcellvertalign ()
end function

public function boolean tablesplitcells ()
end function

public function integer targetdelete ()
end function

public function string targetgetname ()
end function

public function integer targetgoto ()
end function

public function long targetinsert ()
end function

public function long targetnext ()
end function

public function integer targetsetname ()
end function

public function string textfieldgettext ()
end function

public function string textfieldgettype ()
end function

public function integer textfieldgettypedata ()
end function

public function integer textfieldinsert ()
end function

public function integer textfieldsettext ()
end function

public function integer textfieldsettypeanddata ()
end function

public function long textframegetbackcolor ()
end function

public function integer textframegetborderwidth ()
end function

public function integer textframegetinternalmargin ()
end function

public function boolean textframegetmarkerlines ()
end function

public function string textframegettext ()
end function

public function integer textframeinsert ()
end function

public function integer textframeinsertaschar ()
end function

public function integer textframeinsertfixed ()
end function

public function boolean textframeselect ()
end function

public function boolean textframesetbackcolor ()
end function

public function boolean textframesetborderwidth ()
end function

public function boolean textframesetinternalmargin ()
end function

public function boolean textframesetmarkerlines ()
end function

public function boolean textframesettext ()
end function

public function string textline ()
end function

public function integer triggerevent ()
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
