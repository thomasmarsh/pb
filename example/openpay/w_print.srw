HA$PBExportHeader$w_print.srw
$PBExportComments$
forward
global type w_print from window
end type
type dw from datawindow within w_print
end type
end forward

global type w_print from window
integer width = 3237
integer height = 1776
boolean titlebar = true
string menuname = "m_main_print"
boolean controlmenu = true
boolean minbox = true
boolean resizable = true
long backcolor = 80269524
string icon = "res\print.ico"
event ie_checkmenu ( )
event ie_sizewindow ( )
event ie_sizedw ( )
event me_pagesetup ( )
event me_print ( )
event me_zoom ( string as_zoom )
event ie_exit ( )
event ie_retrieve ( )
dw dw
end type
global w_print w_print

type variables



					

	
end variables

forward prototypes
public subroutine of_open ()
end prototypes

event ie_checkmenu;MenuID.EVENT TRIGGER DYNAMIC ie_checkmenu(dw)
end event

event ie_sizewindow;w_main lw_parent
lw_parent = parentwindow()

this.width = lw_parent.mdi_1.Width
this.height = lw_parent.mdi_1.height
move(0,0)


end event

event ie_sizedw;dw.width = this.workspacewidth()
dw.Height = this.workspaceheight() 
dw.move(0,0)
end event

event me_pagesetup;// Άνοιγμα του παραθύρου διαμόρφωσης σελίδας
	OpenWithParm(w_pagesetup, dw)
end event

event me_print;// Άνοιγμα του διαλόγου διαμόρφωσης εκτύπωσης
	OpenWithParm(w_printer, dw)
end event

event me_zoom;dw.modify("Datawindow.print.preview.zoom = '" + as_zoom + "'")
TriggerEvent("ie_checkmenu")
end event

event ie_exit;close(parentwindow())
end event

event ie_retrieve;// Retrieve code goes here
end event

public subroutine of_open ();// Είναι η πρώτη συνάρτηση που εκτελείται μετά το άνοιγμα
end subroutine

on w_print.create
if this.MenuName = "m_main_print" then this.MenuID = create m_main_print
this.dw=create dw
this.Control[]={this.dw}
end on

on w_print.destroy
if IsValid(MenuID) then destroy(MenuID)
destroy(this.dw)
end on

event open;// Τυχόν initialization 	
	of_open()	

// Παίρνουμε το parentwindow και προσαρμόζουμε σε όλο το διαθέσιμο χώρο
	this.TriggerEvent("ie_sizewindow")
	
// Start transaction and check menu
	dw.SetTransObject(SQLCA)
	this.TriggerEvent("ie_checkmenu")
	
// Αλλαγή σε preview mode
	dw.modify("DataWindow.Print.Preview = yes")
	
	
		

end event

event resize;This.TriggerEvent("ie_sizedw")
end event

type dw from datawindow within w_print
integer x = 32
integer y = 32
integer width = 3150
integer height = 1556
integer taborder = 10
string title = "none"
boolean hscrollbar = true
boolean vscrollbar = true
boolean livescroll = true
borderstyle borderstyle = stylelowered!
end type

