HA$PBExportHeader$transaction.sru

global type transaction from nonvisualobject
end type

type variables
boolean AutoCommit
powerobject ClassDefinition
string Database
string DBMS
string DBParm
string DBPass
string Lock
string LogID
string LogPass
string ServerName
long SQLCode
long SQLDBCode
string SQLErrText
long SQLNRows
string SQLReturnData
string UserID
end variables

public function string classname ()
end function

public function long dbhandle ()
end function

public function integer enablesecureconnection (boolean flag)
end function

public function integer getcontextservice (string servicename, powerobject servicereference)
end function

public function powerobject getparent ()
end function

public function string getsecureconnectionstring ()
end function

public function boolean postevent (string event, long word, any long)
end function

public function integer setsecureconnectionproperty ()
end function

public function integer setsecureconnectionstring (string strconnect)
end function

public function string syntaxfromsql (string sqlselect, datawindow presentation, string err)
end function

public function integer triggerevent (string event, long word, long long)
end function

public function any typeof ()
end function

on transaction.constructor
end on

on transaction.dberror
end on

on transaction.dbnotification
end on

on transaction.destructor
end on

on transaction.sqlpreview
end on
