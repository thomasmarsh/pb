// ExportsA.cpp : Export functions for AscII
//

#include "stdafx.h"
#include "formelparser.h"


// int cfn_OlografosEA(double, LPSTR)
// Ολογράφως σε Ευρώ
double APIENTRY cfn_mathparserA(char* expr)
{
	
	CFormulaParser	parser;
	CString			errtext;
	double			result;
	int				error;

	result = parser.Calculation(expr, 0, error, errtext);
	return result;
}