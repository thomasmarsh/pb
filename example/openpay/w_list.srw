HA$PBExportHeader$w_list.srw
$PBExportComments$
forward
global type w_list from window
end type
type dw from datawindow within w_list
end type
end forward

global type w_list from window
integer width = 2281
integer height = 1820
boolean titlebar = true
string menuname = "m_main_list"
boolean controlmenu = true
boolean minbox = true
boolean resizable = true
long backcolor = 80269524
string icon = "AppIcon!"
event me_filter ( )
event ie_retrieve ( )
event ie_checkmenu ( )
event ie_sizedw ( )
event me_add ( )
event me_edit ( )
event me_delete ( )
event me_refresh ( )
event me_search ( )
event me_viewall ( )
event ie_exit ( )
event ie_close ( )
event me_prevwhere ( )
event me_nextwhere ( )
event me_clearhistory ( )
dw dw
end type
global w_list w_list

type variables
// Το όνομα του πίνακα (καταχωρημένο στον afxTable)
	public		string	is_tablename

// The dw's select clause, order by and recent where
	protected	string	is_select
	public 		string 	is_where, is_order

// Τα ονόματα των παραθύρων επεξεργασίας, αναζήτησης και φίλτρου
	public 		string	is_formwin		
	public 		string	is_searchwin
	
// if true το update γίνεται στο dw
	protected	boolean	ib_update		
	
// Αν είναι true η φόρμα επεξεργασίας ανοίγει με 1 (retrieve)
	boolean	ib_editwithkey
	
// Αν είναι true retrieve μετά το άνοιγμα
	protected	boolean	ib_retrieve
	
// Αν είναι true συμπεριλαμβάνεται η λέξη "WHERE" στο φίλτρο
	protected	boolean 	ib_includewhere = false
	
// Επέκταση του παραθύρου σε όλη την client area (if true)
	protected 	boolean	ib_xclient, &
									ib_yclient
								
// Επιτρέπει την ταξινόμηση με κλικ στις κεφαλίδες
	protected 	boolean	ib_sort
	
// Αν είναι true αναζήτηση στο .ini παραμέτρων διαμόρφωσης
	protected 	boolean	ib_useini
	
// Αν είναι true απενεργοποίηση των αντίστοιχων menu
	protected boolean		ib_noview
	protected boolean		ib_nofilter
	
// Alternative row coloring
	protected 	long		il_rowcolor  = rgb(255,255,255) 
	protected 	long		il_rowrcolor = rgb(255,255,128)		
	
// History of where clauses (double linked list)
	public		uc_lnklist	ilst_history
	
end variables

forward prototypes
protected subroutine of_reset_struct ()
protected subroutine of_struct2dw (ref datawindow adw, long row)
protected function string if_opensearch ()
protected function boolean of_checkdelete (ref datawindow adw, long row)
protected subroutine of_init_struct ()
protected function string if_where4print ()
protected subroutine of_dw2struct (ref datawindow adw, long row)
protected subroutine of_open ()
public subroutine of_setrowcolors (ref long al_rowcolor, ref long al_rowrcolor)
protected function boolean if_openform (long param)
public subroutine of_deleterow (ref datawindow adw, long row)
protected subroutine of_retrieve (ref datawindow adw)
public subroutine of_initsqlselect ()
public subroutine of_afterinsert (ref datawindow adw, long row)
public subroutine of_afterupdate (ref datawindow adw, long row)
public subroutine if_readini ()
public subroutine of_afterdelete (ref datawindow adw, long row)
protected subroutine if_setwhere (string as_where)
end prototypes

event me_filter();// Άνοιγμα του παραθύρου φιλτραρίσματος για το tablename του πίνακα

string	ls_where

OpenWithParm(w_filter, is_tablename)

ls_where = Message.StringParm
if ls_where = "" or isnull(ls_where) then return

// Η ls_where είναι της μορφής " AND ..."
// Αν ib_includewhere = true, αντικατάσταση του αρχικού " AND " με " WHERE "
	if ib_includewhere then
		ls_where = right(ls_where, len(ls_where) - 5)
		ls_where = " where " + ls_where
	end if

// Assign new where and retrieve
	if_setwhere(ls_where)
	


end event

event ie_retrieve();// Retrieve με τα τρέχοντα where και order
	
	string	ls_newselect
	
// Η νέα select ταξινομημένη 
	ls_newselect = is_select + " " + is_where + " " + is_order
	
// Set redraw and pointer
	pointer	oldpointer
	dw.SetRedraw(false)
	oldpointer = SetPointer(HourGlass!)
	
	
	dw.Modify("DataWindow.Table.Select='" + ls_newselect + "'")
	of_retrieve(dw)
	
// Select first row
	dw.SelectRow(0, false)
	dw.SetRow(1)
	dw.SelectRow(1, true)

// Restore redraw and pointer
	dw.SetRedraw(true)
	SetPointer(oldpointer)

// Ενεργοποίηση - απενεργοποίηση menu
	this.TriggerEvent("ie_checkmenu")


end event

event ie_checkmenu;MenuID.EVENT TRIGGER DYNAMIC ie_checkmenu(dw)
end event

event ie_sizedw;dw.width = this.workspacewidth()
dw.Height = this.workspaceheight() 
dw.move(0,0)

end event

event me_add();// Προσθήκη μιας νέας εγγραφής

// Έλεγχος δικαιωμάτων
	if not fn_perm(is_tablename, "addrec") then return

// Καθαρισμός της ανάλογης structure
	of_reset_struct()

// Default τιμές για νέα εγγραφή
	of_init_struct()

// Άνοιγμα της φόρμας επεξεργασίας και έλεγχος αν πατήσαμε ΟΚ ή CANCEL (override function)
// parameter = 0 -> νέα εγγραφή (for both updatable and no updateble)
	if not if_openform(0) then return

dw.SetRedraw(false)

// Αν πατήσαμε οκ εισάγουμε μία νέα γραμμή και μεταφέρουμε τα στοιχεία
	long	ll_row
	ll_row = dw.InsertRow(0)
	of_struct2dw(dw, ll_row)	

// Επιλέγουμε την νέα γραμμή
	//dw.SetRow(1)
	dw.SelectRow(0, false)
	dw.ScrollToRow(ll_row)
	dw.SelectRow(ll_row, true)
	dw.SetFocus()
	
dw.SetRedraw(true)
	

// update ανάλογα με την ib_update
	if ib_update then
		dw.update()
		COMMIT;
	end if
	
// check menu
	This.TriggerEvent("ie_checkmenu")

// Καλούμε την of_afterinsert()
	of_afterinsert(dw, ll_row)
	


end event

event me_edit();// Έλεγχος δικαιωμάτων
	if not fn_perm(is_tablename, "openform") then return

// Παίρνουμε την τρέχουσα γραμμή του dw
	long	ll_row
	ll_row = dw.getrow()
	if ll_row = 0 then return

// Καθαρισμός της καθολικής structure (override function)
	of_reset_struct()

// Μεταφορά των δεδομέων στην σχετική structure (override function)
	of_dw2struct(dw, ll_row)
	
// Άνοιγμα της φόρμας επεξεργασίας και έλεγχος αν πατήσαμε ΟΚ ή CANCEL (override function)
// Αν ib_update = true parameter = -1 (τα δεδομένα τα παίρνουμε από structure)
// Αν ib_update = false parameter = 1 (the key of record into structure)
	boolean 	ib_ret
	if ib_editwithkey then
		ib_ret = if_openform(1)
	else
		ib_ret = if_openform(-1)
	end if
	if not ib_ret then return
	
// Τα νέα δεδομένα από την sturcture στο dw
	of_struct2dw(dw, ll_row)
	
// update ανάλογα με την ib_update
	if ib_update then
		dw.update()
		COMMIT USING SQLCA;
	end if
	
// Καλούμε την of_afterupdate()
	of_afterupdate(dw, ll_row)

end event

event me_delete();// Διαγραφή της επιλεγμένης εγγραφής

// Έλεγχος δικαιώματος
	if not fn_perm(is_tablename, "delrec") then return

// Παίρνουμε την τρέχουσα γραμμή του dw
	long	ll_row
	ll_row = dw.getrow()
	if ll_row = 0 then return
	
// Συνάρτηση που ελέγχει διάφορες συνθήκες (π.χ. συνδεδεμένους πίνακες)
	if not of_checkdelete(dw, ll_row) then return
	
// Επαλήθευση
	int	nRet
	nRet = MessageBox(trn(297), trn(454), Exclamation!, OKCancel!, 2)
	if nRet = 2 then return
	
// Αλλαγή κέρσορα σε κλεψύδρα
	pointer	oldpointer
	oldpointer = setpointer(Hourglass!)

// Διαγραφή και επιλογή της αμέσως προηγούμενης γραμμής
	dw.SetRedraw(false)
	of_deleterow(dw, ll_row)
	dw.DeleteRow(ll_row)		// Διαγραφή στο dw χωρίς update
	
	ll_row = ll_row - 1
	if ll_row = 0 then ll_row = 1
	dw.SetRow(ll_row)
	dw.ScrollToRow(ll_row)
	dw.SelectRow(0, false)
	dw.SelectRow(ll_row, true)
	dw.SetFocus()
	
	dw.SetRedraw(true)	

// check menu	
	this.TriggerEvent("ie_checkmenu")
	
// Καλούμε την of_afterdelete()
	of_afterupdate(dw, ll_row)	
	
// Επαναφορά κέρσορα
	setpointer(oldpointer)

end event

event me_refresh;// Ανανέωση περιεχομένων (με την ίδια select)
	This.TriggerEvent("ie_retrieve")

end event

event me_search();// Άνοιγμα του παραθύρου αναζήτησης
	string ls_where
	ls_where = if_OpenSearch()

// Αν επιστρέψαμε "" επιστρέφουμε
	if ls_where = "" then return
	
// Δώσαμε κριτήρια
	if_setwhere(ls_where)

end event

event me_viewall();// Καταργούμε το φίλτρο
// (Δεν προστήθετε το is_history)
	is_where = ""
	This.TriggerEvent("ie_retrieve")
end event

event ie_exit;close(parentwindow())
end event

event ie_close();// Ακύρωση του ανοίγματος
	close(this)
end event

event me_prevwhere();// Show previous where 
	
// Αν επιτύχει η moveprev
	if ilst_history.moveprev() then
		is_where = ilst_history.getposdata()	
		this.triggerevent("ie_retrieve")
	end if
end event

event me_nextwhere();// Show next where 
	
// Αν επιτύχει η movenext
	if ilst_history.movenext() then
		is_where = ilst_history.getposdata()	
		this.triggerevent("ie_retrieve")
	end if
end event

event me_clearhistory();// Διαγράφουμε όλα εκτώς από την τρέχουσα προβολή

// Κρατάμε την τρέχουσα where
	string	ls_curwhere
	ls_curwhere = ilst_history.getposdata()
	
// Άδειασμα λίστας και προσθήκη της τρέχουσας where
	ilst_history.emptylist()
	ilst_history.addtail(ls_curwhere)

	This.TriggerEvent("ie_checkmenu")
	

end event

protected subroutine of_reset_struct ();// Override to clear the relative structure
end subroutine

protected subroutine of_struct2dw (ref datawindow adw, long row);// Ενημερώνεται η επιλεγμένη εγγραφή με τα στοιχεία της structure
// Override in descentant
end subroutine

protected function string if_opensearch ();
// Άνοιγμα του παραθύρου αναζήτησης και επιστροφή της where
	
window		w_searchwin

Open(w_searchwin, is_searchwin)
return Message.StringParm

end function

protected function boolean of_checkdelete (ref datawindow adw, long row);// Εδώ προσθέτουμε έξτρα ελέγχους πριν γίνει η διαγραφή
// π.χ. συνδεδεμένους πίνακες κ.λ.π.
// Αν επιστρέψει false δεν προχωρά η διαγραφή

return true
end function

protected subroutine of_init_struct ();// Default τιμές για νέες εγγραφές (override function)
end subroutine

protected function string if_where4print ();// compines is_where, is_order
	
// Συνδυάζουμε where και order
	string	ls_where, ls_order
	
// Αν στην where και στην order υπάρχουν ' τα αλλάζοουμε σε ~'
	ls_where = is_where
	ls_order = is_order 
	
	ls_where = fn_replace_str(is_where, "'", "~'")
	ls_order = fn_replace_str(is_order, "'", "~'")
	
	return " " + ls_where + " " + ls_order + " "
	
// εκτύπωση ώς εξής (στο menu event του descenant
	//OpenSheetWithParm(wprn_cust_labels, fn_where4print(), w_main, 0, Original!)	

end function

protected subroutine of_dw2struct (ref datawindow adw, long row);// Μεταφορά των πεδίων από το dw στην σχετική structure
// Override in descentant
end subroutine

protected subroutine of_open ();// Εκτελείται ακριβώς μετά το άνοιγμα


end subroutine

public subroutine of_setrowcolors (ref long al_rowcolor, ref long al_rowrcolor);// Καθορισμός εναλλακτικών χρωμάτων
end subroutine

protected function boolean if_openform (long param);// Άνοιγμα του παραθύρου για προσθήκη - επεξεργασία
// Αν επιστρέψαμε με cancel επιστρέψει false
// param: 	   0 -> νέα εγγραφή
//				  -1 -> Επεξεργασία - τα δεδομένα στην global structure
//				   1 -> Επεξεργασία - retrieve (To id στην structure)

window	w_formwindow

OpenWithParm(w_formwindow, param, is_formwin)

if Message.DoubleParm = 1 then
	return true
else
	return false
end if

end function

public subroutine of_deleterow (ref datawindow adw, long row);// override to delete selected row with embended sql
end subroutine

protected subroutine of_retrieve (ref datawindow adw);// Override if arguments required
	dw.retrieve()
end subroutine

public subroutine of_initsqlselect ();// Initialize is_select 
// override to add where that is present always (xrisi for example)
// replace ' with ~'
	is_select = dw.GetSQLSelect()
	is_select = fn_replace_str(is_select, "'", "~~'")
end subroutine

public subroutine of_afterinsert (ref datawindow adw, long row);// Καλείται μετά την προσθήκη νέας εγγραφής

end subroutine

public subroutine of_afterupdate (ref datawindow adw, long row);// Καλείτε μετά την επεξεργασία (edit)
end subroutine

public subroutine if_readini ();// Αναζήτηση στο .ini παραμέτρων διαμόρφωσης του παραθύρου
// use ini only if ib_useini = true

	if not ib_useini then return
	
// Μεταβλητές παραμέτρων
	integer	li_retrieve, &
				li_xclient, &
				li_yclient, &
				li_sort, &
				li_width, &
				li_height
	string	ls_order
	
// Ανάγνωση
	li_retrieve = ProfileInt(gs_ini_file, is_tablename, "retrieve", -1) 
	li_xclient = ProfileInt(gs_ini_file, is_tablename, "xclient", -1)
	li_yclient = ProfileInt(gs_ini_file, is_tablename, "yclient", -1)
	li_sort = ProfileInt(gs_ini_file, is_tablename, "sort", -1)
	li_width = ProfileInt(gs_ini_file, is_tablename, "width", -1)
	li_height = ProfileInt(gs_ini_file, is_tablename, "height", -1)
	ls_order = ProfileString(gs_ini_file, is_tablename, "order", "")
	

// Εκχώρηση τιμών
	
	// retrieve
		if li_retrieve <> -1 then 
			if li_retrieve = 1 then
				ib_retrieve = true
			else 
				ib_retrieve = false
			end if
		end if
		
	// xclient
		if li_xclient <> -1 then
			if li_xclient = 1 then
				ib_xclient = true
			else
				ib_xclient = false
			end if
		end if
		
	// yclient
		if li_yclient <> -1 then
			if li_yclient = 1 then
				ib_yclient = true
			else
				ib_yclient = false
			end if
		end if
	
	// sort
		if li_sort <> -1 then
			if li_sort = 1 then
				ib_sort = true
			else
				ib_sort = false
			end if
		end if
		
	// width
		if li_width <> -1 then this.width = li_width
		
	// height
		if li_height <> -1 then this.height = li_height
		
	// order
		if ls_order <> "" then is_order = ls_order
		
		

		
		
	
	
			
end subroutine

public subroutine of_afterdelete (ref datawindow adw, long row);// Καλείτε μετά την διαγραφή
end subroutine

protected subroutine if_setwhere (string as_where);// set the where clause to local variable
// insert into ilst_history

	is_where = as_where
	ilst_history.addpos(as_where)
	
	this.TriggerEvent("ie_retrieve")
	
	

end subroutine

on w_list.create
if this.MenuName = "m_main_list" then this.MenuID = create m_main_list
this.dw=create dw
this.Control[]={this.dw}
end on

on w_list.destroy
if IsValid(MenuID) then destroy(MenuID)
destroy(this.dw)
end on

event open;of_open()

// .ini configuration
	if_readini()

// Start transaction 
// and get initial select clause
	dw.SetTransObject(SQLCA)
	of_initsqlselect()
	
// Διαστάσεις του παραθύρου ανάλογα με 
// ib_xClient, ib_yClient
	w_main lw_parent
	lw_parent = parentwindow()
	if ib_xClient then this.width = lw_parent.mdi_1.Width
	if ib_yClient then this.height = lw_parent.mdi_1.height

// Size dw and check menu
	TriggerEvent("ie_sizedw")
	TriggerEvent("ie_checkmenu")
	
// Retrieve αν ib_retrieve είναι true
	if ib_retrieve then TriggerEvent("ie_retrieve")

// Άνοιγμα στην κορυφή
	move(0,0)
	
// Παίρνουμε τον τίτλο από afxTable με βάση το is_tablename
	string	ls_title
	select tabledesc into :ls_title from dba.afxTable where tablename = :is_tablename;
	if not isnull(ls_title) and not ls_title = "" then this.title = ls_title
	
// Make alternative row coloring
	of_setrowcolors(il_rowcolor, il_rowrcolor)
	dw.Modify("DataWindow.Detail.Color= '536870912~tif(mod(getrow(), 2) = 1, " + string(il_rowcolor) + ", " + string(il_rowrcolor) + ")'")
	
// Απενεργοποίηση επιλογών Menu
	if ib_noview then MenuID.TriggerEvent("ie_noview")
	if ib_nofilter then MenuID.TriggerEvent("ie_nofilter")
	

end event

event resize;This.TriggerEvent("ie_sizedw")
end event

type dw from datawindow within w_list
integer width = 2235
integer height = 1400
integer taborder = 10
string title = "none"
boolean hscrollbar = true
boolean vscrollbar = true
boolean livescroll = true
borderstyle borderstyle = stylelowered!
end type

event rowfocuschanging;this.SelectRow(currentrow, false)
this.Selectrow(newrow, true)
		
end event

event doubleclicked;GetParent().TriggerEvent("me_edit")
end event

event clicked;String	ls_old_sort, ls_column
char		lc_sort

// Έλεγχος αν επιτρέπεται η ταξινόμηση
	if not ib_sort then return
	if right(dwo.name, 2) <> '_t' then return 
	
// The user have clicked on a column - sort
	
	SetRedraw(false)

	ls_column = left(dwo.name, len(string(dwo.name))-2)
	// Get old sort, if any
		ls_old_sort = dw.Describe("Datawindow.Table.sort")
	// Check whether previously sorted columhn and currently clicked
	// column are same or not. If both are same then check for the sort
	// order of previously sorted column (A - Asc, D - Desc) and change it.
	// If both are not same then simply sort it by Ascending order
		if ls_column = left(ls_old_sort, len(ls_old_sort)-2) then
			lc_sort = right(ls_old_sort,1)
			if lc_sort = 'A' then 
				lc_sort = 'D'
			else
				lc_sort = 'A'
			end if
			dw.SetSort(ls_column + " " + lc_sort)
		else
			dw.SetSort(ls_column + " A")
		end if
	dw.Sort()
	
	// Select firt row
		dw.SelectRow(0,false)
		dw.ScrollToRow(1)
		dw.SelectRow(1,true)
	
setredraw(true)
end event

event rbuttondown;// Αν η νέα εγγραφή είναι διαφορετική από την 
// προηγούμενη, την επιλέγουμε
	long	ll_oldrow
	ll_oldrow = this.getrow()
	if ll_oldrow <> row and row <> 0 then 
		this.Setrow(row)
		this.SelectRow(ll_oldrow, false)
		this.SelectRow(row, true)
	end if

// popup
	m_main_list		menu
	menu = menuid
	menu.m_popup.PopMenu(parentwindow().pointerx(), parentwindow().pointery())
end event

