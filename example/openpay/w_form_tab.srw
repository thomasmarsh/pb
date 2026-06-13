HA$PBExportHeader$w_form_tab.srw
$PBExportComments$
forward
global type w_form_tab from window
end type
type tab1 from tab within w_form_tab
end type
type page1 from userobject within tab1
end type
type dw_main from datawindow within page1
end type
type page1 from userobject within tab1
dw_main dw_main
end type
type page2 from userobject within tab1
end type
type page2 from userobject within tab1
end type
type tab1 from tab within w_form_tab
page1 page1
page2 page2
end type
type cb_cancel from commandbutton within w_form_tab
end type
type cb_ok from commandbutton within w_form_tab
end type
end forward

global type w_form_tab from window
integer width = 1943
integer height = 1400
boolean titlebar = true
boolean controlmenu = true
windowtype windowtype = response!
long backcolor = 67108864
string icon = "AppIcon!"
boolean center = true
tab1 tab1
cb_cancel cb_cancel
cb_ok cb_ok
end type
global w_form_tab w_form_tab

type variables
protected boolean		ib_newrec		// Αν είναι true είναι νέα εγγραφή
public	 boolean 	ib_update		// Αν είναι true το κάνουμε update πριν επιστρέψουμε
protected boolean		ib_useptoseis	// Χρήση πτώσεων (ναι/όχι)
protected string		is_tablename	// Για έλεγχο δικαιωμάτων

// Τα dw's σε τοπικές
public	datawindow	idw_main

// Πίνακας με ονόματα πεδίων που συμετέχουν σε πτώσεις	
protected string		ias_ptoseis[]
end variables

forward prototypes
protected subroutine of_accepttext ()
protected subroutine of_insertrows ()
protected subroutine of_settransactions ()
protected subroutine of_storekey ()
protected subroutine of_update ()
protected subroutine of_retrieve ()
protected subroutine of_open ()
protected subroutine if_lockfield (ref datawindow adw, string col)
public subroutine of_sharedws ()
public subroutine if_unlockfield (ref datawindow adw, string as_col)
public function boolean of_check4required (ref datawindow adw, long row)
public subroutine of_dw2struct (ref datawindow adw, long row)
public subroutine of_struct2dw (ref datawindow adw, long row)
public subroutine of_disabledws ()
public function boolean of_ok ()
public subroutine of_setmasks ()
end prototypes

protected subroutine of_accepttext ();// Accept text for all dw's
	idw_main.AcceptText()
end subroutine

protected subroutine of_insertrows ();// Εισαγωγή γραμμών στα dw's
	idw_main.InsertRow(0)
end subroutine

protected subroutine of_settransactions ();// Set Transaction for all dw's
	idw_main.SetTransObject(SQLCA)
end subroutine

protected subroutine of_storekey ();// Αποθήκευση του κλειδιού (μπορεί να είναι περισσότερα από ένα πεδία)
// σε τοπικές μεταβλητές (αφού οριστούν στο descenant)
// Το (τα) κλειδί βρίσκεται συνήθως στην καθολική structure
// Μπορεί όμως να είναι οπουδήποτε
end subroutine

protected subroutine of_update ();// update του dw
// (override if there is more dw's
	idw_main.update()
	COMMIT USING SQLCA;
end subroutine

protected subroutine of_retrieve ();// Override of_storekey first to take the key 
// into local variables

end subroutine

protected subroutine of_open ();// Εκτελείται αμέσως μετά το άνοιγμα 

idw_main = tab1.page1.dw_main
end subroutine

protected subroutine if_lockfield (ref datawindow adw, string col);// Απενεργοποιεί το col του adw:
// 1) Tabsequence = 0 
// 2) Background color = adw's detail color
	
	string	ls_bkcolor
	
	// Παίρνουμε το bkcolor του detail του ls_dw
		ls_bkcolor = adw.Describe("DataWindow.Detail.Color")
		
	// Αλλαγή tabsequence και background of col
		adw.Modify(col + ".Background.Color='" + ls_bkcolor + "'")
		adw.Modify(col + ".TabSequence='0'")

end subroutine

public subroutine of_sharedws ();// Share datawindows
end subroutine

public subroutine if_unlockfield (ref datawindow adw, string as_col);// 1) Tabsequence = 1000
// 2) Background color = λευκό (255,255,255)
	
// Αν το tabSequence δεν είναι 0 είναι ήδη ξεκλειδωμένο
	string	ls_lockstate
	ls_lockstate = adw.Describe(as_col + ".TabSequence")
	if ls_lockstate <> "0" then return
	
	long	ll_bkcolor
	
	// Παίρνουμε το bkcolor του detail του ls_dw
		ll_bkcolor = rgb(255,255,255)
		
	// Αλλαγή tabsequence και background of col
		adw.Modify(as_col + ".Background.Color='" + string(ll_bkcolor) + "'")
		adw.Modify(as_col + ".TabSequence='100'")
end subroutine

public function boolean of_check4required (ref datawindow adw, long row);/*
string	lstring	
long		llong	
date		ldate
time		ltime

// string
	lstring = adw.object.xxx[row]
	if isnull(lstring) or lstring = "" then
		Messagebox(gs_app_name, " .....")
		adw.setfocus()
		adw.setcolumn("xxx")
		return false
	end if
	
	// Έλεγχος αν ο κωδικός έχει καταχωρηθεί
		if lstring <> is_xxx or isnull(is_xxx) or is_xxx = "" then
			select count(xxx) into :ll_count from yyy
			where xxx = :lstring;
			fn_sqlerror()
			if ll_count > 0 then
				Messagebox(gs_app_name, "Code exists")
				adw.setfocus()
				adw.setcolumn("xxx")
				return false
			end if
		end if
	

// long
	llong	= adw.object.xxx[row]
	if isnull(llong) then
		Messagebox(gs_app_name, "....")
		adw.setfocus()
		adw.setcolumn("xxx")
		return false
	end if
	
// date
	ldate	= adw.object.xxx[row]
	if isnull(ldate) then
		Messagebox(gs_app_name, ".....")
		adw.setfocus()
		adw.setcolumn("xxx")
		return false
	end if	
	
// time
	ltime	= adw.object.xxx[row]
	if isnull(ltime) then
		Messagebox(gs_app_name, ".....")
		adw.setfocus()
		adw.setcolumn("xxx")
		return false
	end if	

*/
	
// everything ok
	return true
end function

public subroutine of_dw2struct (ref datawindow adw, long row);// Μεταφορά τιμών από dw στην σχετική structure
end subroutine

public subroutine of_struct2dw (ref datawindow adw, long row);// Μεταφορά στοιχείων από structure σε dw (override)
	
end subroutine

public subroutine of_disabledws ();// Απενεργοποίηση των dw's αν δεν έχουμε δικαίωμα ενημέρωσης
	idw_main.enabled = false
end subroutine

public function boolean of_ok ();return true
end function

public subroutine of_setmasks ();// Edit Mask & display Mask

/*

// maskdate, maskdateedit
	fn_seteditmask(idw_main, "xxxxx", fn_param_maskdateedit())
	fn_setformatmask(idw_main, "xxxxx", fn_param_maskdate())

// maskposo, maskposoedit
	fn_seteditmask(idw_main, "xxxxx", fn_param_maskposoedit())
	fn_setformatmask(idw_main, "xxxxx", fn_param_maskposo())
	
// maskposotita, maskposotitaedit
	fn_seteditmask(idw_main, "xxxxx", fn_param_maskposotitaedit())
	fn_setformatmask(idw_main, "xxxxx", fn_param_maskposotita())

// masktime, masktimeedit
	fn_seteditmask(idw_main, "xxxxx", fn_param_masktimeedit())
	fn_setformatmask(idw_main, "xxxxx", fn_param_masktime())

*/
end subroutine

on w_form_tab.create
this.tab1=create tab1
this.cb_cancel=create cb_cancel
this.cb_ok=create cb_ok
this.Control[]={this.tab1,&
this.cb_cancel,&
this.cb_ok}
end on

on w_form_tab.destroy
destroy(this.tab1)
destroy(this.cb_cancel)
destroy(this.cb_ok)
end on

event open;// Τυχόν initializing στην of_open
	of_open()

// Start transaction for all dw's
	of_settransactions()

// Παίρνουμε το message:
// 0 = νέα εγγραφή
// -1 = επεξεργασία (τα δεδομένα στην structure)
// 1 = επεξεργασία - retrieve (το κλειδί σε τοπικές μεταβλητές - overwrite of_storekey()) 
// Προσοχή: Όταν είναι -1 δεν μπορεί να είναι update
	long	ll_temp
	ll_temp = Message.DoubleParm
	of_storekey()
	
// Ανάλογα με το ll_temp
	choose case ll_temp
		case 0	// νέα εγγραφή
			ib_newrec = true
			of_insertrows()
			of_struct2dw(idw_main, 1)		// για initialize values
			
		case -1	// Επεξεργασία (τα δεδομένα στην structure)
			ib_newrec = false
			of_insertrows()
			of_struct2dw(idw_main, 1)		// για μεταφορά των δεδομένων
			
		case 1 // Επεξεργασία - retrieve (το κλειδί στην structure και το παίρνουμε με of_getkey()
			ib_newrec = false
			of_retrieve()		// retrieve ανάλογα με το κλειδί
			
	end choose
	
// set focus to idw_main
	idw_main.SetFocus()
	
// Sharing goes here
	of_sharedws()
	
// Έλεγχος αν ο χρήστης έχει δικαίωμα ενημέρωσης
	if not fn_perm(is_tablename, "editrec") then of_disabledws()

// Edit & display masks
	of_SetMasks()
	
// Translation	
	cb_ok.text = trn(699)
	cb_cancel.text = trn(2)
	
end event

type tab1 from tab within w_form_tab
integer x = 14
integer y = 8
integer width = 1897
integer height = 1100
integer taborder = 10
integer textsize = -10
integer weight = 400
fontcharset fontcharset = greekcharset!
fontpitch fontpitch = variable!
fontfamily fontfamily = swiss!
string facename = "Arial Greek"
long backcolor = 67108864
boolean raggedright = true
boolean focusonbuttondown = true
integer selectedtab = 1
page1 page1
page2 page2
end type

on tab1.create
this.page1=create page1
this.page2=create page2
this.Control[]={this.page1,&
this.page2}
end on

on tab1.destroy
destroy(this.page1)
destroy(this.page2)
end on

type page1 from userobject within tab1
integer x = 18
integer y = 112
integer width = 1861
integer height = 972
long backcolor = 67108864
string text = "none"
long tabtextcolor = 16711680
long picturemaskcolor = 67108864
dw_main dw_main
end type

on page1.create
this.dw_main=create dw_main
this.Control[]={this.dw_main}
end on

on page1.destroy
destroy(this.dw_main)
end on

type dw_main from datawindow within page1
event ue_keydown pbm_dwnkey
integer x = 5
integer y = 36
integer width = 1842
integer height = 928
integer taborder = 20
string title = "none"
boolean border = false
boolean livescroll = true
end type

event ue_keydown;	string	ls_null, ls_col, ls_coltype, ls_data
	long		ll_row

	setnull(ls_null)
	
	choose case key
			/*
		case KeyDelete!
			// Set null to dropdowns που δεν επιτρέπουν edit
				ls_col = this.GetColumnName()
				ll_row = this.getrow()
				
				choose case ls_col
						
					case "xxxx"
						this.object.xxxx[ll_row] = ls_null
					
				end choose
			*/
		case keyf2!
			// Αν είμαστε σε πεδίο ημ/νίας, δίνουμε την τρέχουσα
				ls_col = this.GetColumnName()
				ll_row = this.GetRow()
			
			// Αν δεν είναι πεδίο ημ/νίας, επιστρέφουμε
				ls_coltype = this.Describe(ls_col + ".coltype")
				if ls_coltype <> "date" then return
				
			// Δίνουμε τη σημερινή ημ/νία
				this.SetItem(ll_row, ls_col, today())
				// Send tab message to move to the next column
					Send(Handle(this),256,9,Long(0,0)) 
					
		case keyf3!
					
			if not ib_useptoseis then return		// flag
			
			this.AcceptText()			
				
			// Παίρνουμε το όνομα του πεδίου
				ls_col = this.GetColumnName()
				ll_row = this.GetRow()
				
			// Αν το πεδίο είναι μέλος του ias_ptoseis
			// ανοίγουμε το παράθυρο πτώσεων
				if fn_strinarray(ias_ptoseis[] , ls_col) then
					ls_data = this.GetItemString(ll_row, ls_col)	
					if not isnull(ls_data) and ls_data <> "" then OpenWithParm(w_afxptoseis_form, ls_data)
				end if

	end choose

end event

event losefocus;this.accepttext()
end event

type page2 from userobject within tab1
integer x = 18
integer y = 112
integer width = 1861
integer height = 972
long backcolor = 67108864
string text = "none"
long tabtextcolor = 16711680
long picturemaskcolor = 67108864
end type

type cb_cancel from commandbutton within w_form_tab
integer x = 1595
integer y = 1144
integer width = 311
integer height = 100
integer taborder = 30
integer textsize = -9
integer weight = 400
fontcharset fontcharset = greekcharset!
fontpitch fontpitch = variable!
fontfamily fontfamily = swiss!
string facename = "Arial Greek"
string text = "&Ακύρωση"
boolean cancel = true
end type

event clicked;// Επιστροφή με cancel

	CloseWithReturn(GetParent(), 0)
end event

type cb_ok from commandbutton within w_form_tab
integer x = 1239
integer y = 1144
integer width = 311
integer height = 100
integer taborder = 20
integer textsize = -9
integer weight = 400
fontcharset fontcharset = greekcharset!
fontpitch fontpitch = variable!
fontfamily fontfamily = swiss!
string facename = "Arial Greek"
string text = "&ΟΚ"
boolean default = true
end type

event clicked;// Επστρέφουμε με τις τιμές που δώσαμε

	of_AcceptText()
	
// Check of_ok()
	if not of_ok() then return

// Αν λείπουν υποχρεωτικά πεδία δεν προχωράμε
	if not of_check4required(idw_main, 1) then return

// Τα στοιχεία πίσω στην structure
	of_dw2struct(idw_main, 1)
	
// Αν είναι update ανανεώνουμε το dw_main
	if ib_update then
		of_update()
		COMMIT USING SQLCA;
	end if

// Επιστροφή με ΟΚ		
	CloseWithReturn(GetParent(), 1)


end event

