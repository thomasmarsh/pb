HA$PBExportHeader$w_filter.srw
$PBExportComments$
forward
global type w_filter from w_response
end type
type uo_filter from u_filter_grid within w_filter
end type
end forward

global type w_filter from w_response
integer width = 2679
integer height = 1348
string title = "Filter"
string icon = "D:\projects\share\res\filter.ico"
uo_filter uo_filter
end type
global w_filter w_filter

type variables
// Το Όνομα του dw που περιέχει τα πεδία
// initialize in descenant
	string	is_dw_fields

// Αν είναι true συμπεριλαμβάνεται η λέξη "WHERE" 
// αν είναι false έχει την μορφή " AND ....."
	boolean	ib_includewhere	
	
// Ο πίνακας - Το παίρνουμε κατά το άνοιγμα
	string	is_tablename

// Το dw του u_filter
	datawindow	idw_filter

end variables

forward prototypes
protected function string fn_buildwhere ()
public function boolean fn_isvaluevalid (long row)
protected function string fn_fixvalue (long row)
end prototypes

protected function string fn_buildwhere ();// Σχηματίζει την πρόταση where σύμφωνα με τα κριτήρια που δώσαμε
// Αν το ib_includewhere είναι true έχει τη μορφή " WHERE ......."
// και αν είναι false " AND ................. "
// Σε κάθε περίπτωση ξεκινάμε με νέο γκρουπ
	string	ls_where
	string	ls_field, ls_operator, ls_value, ls_join
	
	if ib_includewhere then
		ls_where = " WHERE (("	
	else
		ls_where = " AND (("
	end if
	
// Παίρνουμε τις γραμμές του iidw_filter
	long	rows, i
	rows = idw_filter.rowcount()
	
for i = 1 to rows - 1	// Δεν παίρνουμε την γραμμή νέας εγγραφής
	
	// Παίρνουμε τα δεδομένα της γραμμής
		ls_field = idw_filter.object.field[i]
		ls_operator = idw_filter.object.operator[i]
		ls_value = fn_fixvalue(i)
		ls_join = idw_filter.object.join[i]
		
	// Τα προσθέτουμε στην ls_where και κλείνουμε την απλή παρένθεση
		ls_where = ls_where + "(" + ls_field + " " + ls_operator + " " + ls_value + ")"
		
	// Αν είμαστε στην τελευταία γραμμή αγνοούμε το ls_join
	// και κλείνουμε το γκρουπ και την ls_where 
		if i = rows - 1 then
			ls_where = ls_where + "))"		// κλείνουμε το γκρουπ και την ls_where
			return ls_where					// Η επιστροφή γίνεται πάντα απ΄ εδώ
		end if
		
	// Αν δεν είμαστε στην τελευταία γραμμή ελέγχουμε για αλλαγή γκρουπ
		choose case ls_join
			
			case "and (", "or ("		// Αρχίζει νέο γκρουπ
				ls_where = ls_where + ") " + ls_join
				
			case "and", "or"			// Νέα πρόταση στο ίδιο γκρουπ
				ls_where = ls_where + " " + ls_join
		
		end choose
	
next		// next row

return ""		
end function

public function boolean fn_isvaluevalid (long row);// Ελέγχει αν η τιμή συμφωνεί με τον τύπο δεδομένων
// του πεδίου της γραμμής row
	
// Παίρνουμε τον τύπο του πεδίου
	string ls_typos, ls_fieldname
	ls_fieldname = idw_filter.object.field[row]
	select fieldtype into :ls_typos from afxtablefields
	where tablename = :is_tablename and fieldname = :ls_fieldname;

// Αντικατάσταση των @@... με τις πραγματικές τιμές
	string	ls_value
	ls_value = idw_filter.object.value[row]
	
	choose case ls_value
		
		case trn(49)
			ls_value = "null"
			
		case trn(50)
			ls_value = "1"
			
		case trn(51)
			ls_value = "0"
			
	end choose

// Έλεγχος ανάλογα με τον τύπο	
	choose case ls_typos
			
		case "string"
			return true		// strings are always valid
			
		case "date"
			if ls_value = "null" then return true		// null is always valid
			if isdate(ls_value) then 
				return true
			else 
				MessageBox(trn(572), trn(358))
				idw_filter.SetFocus()
				idw_filter.SetRow(row)
				idw_filter.setColumn("value")
				return false
			end if
				
		case "number"
			if ls_value = "null" then return true		// null is always valid
			if isnumber(ls_value) then
				return true
			else
				MessageBox(trn(572), trn(357))
				idw_filter.SetFocus()
				idw_filter.SetRow(row)
				idw_filter.setColumn("value")
				return false
			end if
			
		case "time"
			if ls_value = "null" then return true		// null is always valid
			if istime(ls_value) then
				return true
			else
				MessageBox(trn(572), trn(359))
				idw_filter.SetFocus()
				idw_filter.SetRow(row)
				idw_filter.setColumn("value")
				return false
			end if
			
		case else
			MessageBox("error", "w_filter - field type not specified")
			return false
						
	end choose

end function

protected function string fn_fixvalue (long row);// Προσαρμόζει την τιμή της γραμμής row του idw_filter
//	ανάλογα με τον τύπο του πεδίου της συγκεκριμένης γραμμής
// string: 		add '...'
// date,time  convert to valid date-time and add '...'
// number: replace "," with "."	(decimal point)
	
string	ls_field, ls_typos, ls_value, ls_newvalue

// Παίρνουμε το όνομα του πεδίου και την τιμή του 
	ls_field = idw_filter.object.field[row]
	ls_value = idw_filter.object.value[row]
	
// Αντικατάσταση των @@... με τις πραγματικές τιμές
	choose case ls_value
		
		case trn(49)
			ls_value = "null"
			
		case trn(50)
			ls_value = "1"
			
		case trn(51)
			ls_value = "0"
			
	end choose
		
// Αν είναι "null" αγνοούμε τον τύπο και το αφήνουμε όπως είναι
	if ls_value = "null" then return ls_value

// Βρίσκουμε τον τύπο για το ls_field 
	select fieldtype into :ls_typos from afxtablefields
	where tablename = :is_tablename and fieldname = :ls_field;
	fn_sqlerror()
		
// Προσαρμογή τιμής ανάλογα με τον τύπο
	choose case ls_typos
			
		case "string", "time"		// add ''
			ls_newvalue = "~~'" + ls_value + "~~'"
			
		case "date"			// convert to valid format and add ''
			ls_newvalue = "~~'" + fn_date2string(date(ls_value)) + "~~'"
			
		case "number"		// leave as it is
			ls_newvalue = fn_replace_str(ls_value, ",", ".")
			
	end choose
	 
	return ls_newvalue

end function

on w_filter.create
int iCurrent
call super::create
this.uo_filter=create uo_filter
iCurrent=UpperBound(this.Control)
this.Control[iCurrent+1]=this.uo_filter
end on

on w_filter.destroy
call super::destroy
destroy(this.uo_filter)
end on

event open;call super::open;// Αποθηκεύουμε το message (tablename) στο is_tablename
	is_tablename = Message.StringParm

// Παίρνουμε το dw στην τοπική
	idw_filter = uo_filter.dw
	idw_filter.retrieve()
	idw_filter.setfocus()

// retrieve fields for tablename
	datawindowchild	ldwch
	idw_filter.GetChild("field", ldwch)
	ldwch.SetTransObject(sqlca)
	ldwch.retrieve(is_tablename)
	
// give parent to uo_filter
	uo_filter.iw_parent = this
	uo_filter.triggerevent("ie_checkbuttons")
	
// Translation
	title = trn(218)

end event

type cb_cancel from w_response`cb_cancel within w_filter
integer x = 2313
integer y = 1080
integer taborder = 50
end type

type cb_ok from w_response`cb_ok within w_filter
integer x = 1957
integer y = 1080
integer taborder = 40
end type

event cb_ok::clicked;// Έλεγχος καταχωρήσεων
	if not uo_filter.if_update()	then return
	
// Ελέγχουμε αν δώσαμε σύνδεση για όλες τις εγγραφές - εκτώς από την τελευταία
// (δεν ελέγχεται από την of_check4required)
	long	ll_rows, i
	string	ls_join
	ll_rows = idw_filter.rowcount()
	for i = 1 to ll_rows - 2 // όχι την κενή και την τελευταία
		ls_join = idw_filter.object.join[i]
		if isnull(ls_join) or ls_join = "" then
			MessageBox(trn(218), trn(199))
			idw_filter.setfocus()
			idw_filter.setrow(i)
			idw_filter.SetColumn("join")
			return
		end if
	next
		
// Δημιουργούμε την where
// (χωρίς την λέξη "WHERE" γιατί το parent μπορεί να την έχει ήδη)
	string	ls_where
	ls_where = fn_BuildWhere()
	if ls_where = "" then
		MessageBox(trn(218), trn(198))
		return
	end if
	
// Επιστρέφουμε το δημιουργηθέν φίλτρο
	CloseWithReturn(getparent(), ls_where)
end event

type uo_filter from u_filter_grid within w_filter
event destroy ( )
integer x = 27
integer y = 28
integer taborder = 20
boolean bringtotop = true
end type

on uo_filter.destroy
call u_filter_grid::destroy
end on

