'==================================================================================
' Script Name  : check_smartarray.vbs
' Usage Syntax : cscript.exe //NoLogo //T:10 check_smartarray.vbs [--hpacucli <path>|-h]
' Author       : Alex Simenduev, PlanetIT.WS (http://www.planetit.ws)
' Version      : 1.0.1
' LastModified : 25/08/2008
' Description  : Check status of HP Smart Array Controller Series by using hpacucli
'                The output is compatibe with Nagios.
'                Default Exit code is 3 (STATE_UNKNOWN)
' Note:
' This script is based on the BASH shell script taken from HP forum:
' http://forums12.itrc.hp.com/service/forums/questionanswer.do?threadId=1128853
' Also make sure you using a latest version of "HP Array Configuration Utility CLI" 
'
' License:
'    1: This script is supplied as-is without any support, I hope it works for you.
'    2: You free to modify/distribute this script as you wish, but you must have
'       the folowing line in the script:
'       Original author Alex Simenduev, PlanetIT.WS (http://www.planetit.ws)
'    3: I cannot guaranty that this script works in all cases,
'       please report bugs to shamil.si(at)gmail.com
'
' Change Log:
'    Version 1.0.1:
'                  [+] Added constant for script version
'                  [+] Added commandline arguments, use "-h" for usage help
'                  [*] Other small/minor changes
'    Version 1.0b:
'                  [!] Fixed a bug when another instance of ACU is running
'                      A warning state will be produced in such situation.
'    Version 0.9b:
'                  [*] Initial release.
'==================================================================================
Option Explicit

' Script version Constant
Const VERSION = "1.0.1"

' Nagios states Constants
Const STATE_OK=0
Const STATE_WARNING=1
Const STATE_CRITICAL=2
Const STATE_UNKNOWN=3
Const STATE_DEPENDENT=4

' Text of the hpacucli.exe error when another instance of ACU is running.
Const ANOTHER_INSTANCE_ERROR = "Another instance of ACU is already running (possibly a service)."

' Constant of arguments used with hpacucli.exe command.
Const HPACUCLI_ARGS = "ctrl all show config detail"

' Global variables
Dim gaStates		: gaStates = Array("OK", "WARNING", "CRITICAL", "UNKNOWN", "DEPENDENT")
Dim giExitStatus	: giExitStatus = STATE_UNKNOWN
Dim gsUsage			: gsUsage = "Usage: " & Wscript.ScriptName & " [--hpacucli <path>|-h]"
Dim gsHpacucliPath	: gsHpacucliPath = "hpacucli.exe"
Dim gsHpacucli		: gsHpacucli = ""

' Main excecution region
Dim StdOut			: Set StdOut = Wscript.Stdout

' If no arguments specified, then start the checking with default options
If Wscript.Arguments.Count = 0 Then
		gsHpacucli = parse_hpacucli(run_hpacucli(HPACUCLI_ARGS))		
		Stdout.WriteLine gaStates(giExitStatus) & " - " & gsHpacucli

' If 1 argument was specified and it is "-h" or "--help", then print help message
ElseIf Wscript.Arguments.Count = 1 Then
	If Lcase(Wscript.Arguments.Item(0)) = "-h" Or Lcase(Wscript.Arguments.Item(0)) = "--help" Then
		StdOut.WriteLine "HP Smartarray check plugin for Nagios, version " & VERSION	
		StdOut.WriteLine "(C) 2008, Alex Simenduev - shamil.si(at)gmail.com" & vbNewLine
		StdOut.WriteLine gsUsage
		StdOut.WriteLine vbTab & "-h, --help          print this help message"
		StdOut.WriteLine vbTab & "--hpacucli <path>   set the full <path> of hpacucli.exe utility"	
	Else
		StdOut.WriteLine gsUsage
	End If

' If 2 arguments were specified and first is "--hpacucli", then set
' hpacucli.exe path from the second argument and start the checking
ElseIf Wscript.Arguments.Count = 2 Then
	If Lcase(Wscript.Arguments.Item(0)) = "--hpacucli" Then
		gsHpacucliPath = Wscript.Arguments.Item(1)
		If Right(gsHpacucliPath, 1) = "\" Then
			gsHpacucliPath = gsHpacucliPath & "hpacucli.exe"
		Else
			gsHpacucliPath = gsHpacucliPath & "\hpacucli.exe"
		End If

		gsHpacucli = parse_hpacucli(run_hpacucli(HPACUCLI_ARGS))		
		Stdout.WriteLine gaStates(giExitStatus) & " - " & gsHpacucli
	Else
		StdOut.WriteLine gsUsage
	End If

' If more then 2 arguments were specified, then print usage
Else
		StdOut.WriteLine gsUsage
End If

Wscript.Quit(giExitStatus)

' Function Name : run_hpacucli(pArguments)
' Return value  : String
' Description   : Runs the hpacucli.exe command, and returns it's output.
Function run_hpacucli(pArguments) : run_hpacucli = "" : On Error Resume Next
	Dim objShell : Set objShell = WScript.CreateObject("WScript.Shell")
	Dim objExec  : Set objExec = objShell.Exec(gsHpacucliPath & " " & pArguments)
	Dim strLine
	
	If Err.Number <> 0 Then
		run_hpacucli = "Error (" & Err.Number & "): " & Err.Description
	Else
		Do Until objExec.StdOut.AtEndOfStream
			strLine = objExec.StdOut.ReadLine()
			
			If InStr(strLine, ANOTHER_INSTANCE_ERROR) > 0 Then
				run_hpacucli = ANOTHER_INSTANCE_ERROR
				Exit Do
			Else
				run_hpacucli = run_hpacucli & strLine & vbNewLine
			End If
		Loop
	End If
	
	Set objExec = Nothing
	Set objShell = Nothing
End Function

' Sub Name     : rset_exit_status(pStatus)
' Description  : Sets global exit status
Sub set_exit_status(pStatus)
	If pStatus = "OK" Then
		If giExitStatus > STATE_CRITICAL Then
			giExitStatus = STATE_OK
		End If
	ElseIf pStatus = "Predictive Failure" Then
		If giExitStatus <> STATE_CRITICAL Then
			giExitStatus = STATE_WARNING
		End If
	Else
		giExitStatus = STATE_CRITICAL
	End If
End Sub

' Function Name : unset(pVariables)
' Return value  : String
' Description   : This function will unset all specified variables.
'                 Variables delimeted by space.
' Note          : This script must run wiht Execute function
'                 Otherwise this function will not work!
'
' Example       : Execute unset("var1 var2")
Function unset(pVariables) : unset = ""
	Dim arrVars : arrVars = Split(pVariables, " ")
	Dim strVar
	
	For Each strVar in arrVars
		unset = unset & strVar & " = """"" & vbNewLine
	Next
End Function

' Function Name : parse_hpacucli(pUnparsed)
' Return value  : String
' Description   : This is the main logic function that parses 'hpacucli.exe' output.
' Note          : I've checked this function as much as possible, 
'                 but I cannot guaranty that it 100% will work, please report bugs!
Function parse_hpacucli(pUnparsed) : parse_hpacucli = ""
	' Check if a returned hpacucli.exe output conating ANOTHER_INSTANCE_ERROR Error.
	' If it is, then do not continue to parse the output, and exit with WARNING state.
	If pUnparsed = ANOTHER_INSTANCE_ERROR Then
		parse_hpacucli = ANOTHER_INSTANCE_ERROR
		giExitStatus = STATE_WARNING
		
		Exit Function
	End If

	Dim strLine, arrLines : arrLines = Split(pUnparsed, vbNewLine)
	Dim strLookFor, strOutput, strCtrlName, strCtrlBS, strCtrlCA, strCtrlCR, strLString, strLID, strLST, strPString, strPID, strPST
	Execute unset("strLookFor strOutput strCtrlName strCtrlBS strCtrlCA strCtrlCR strLString strLID strLST strPString strPID strPST")
	
	For Each strLine in arrLines
		If strLine <> "" Then
			If Left(strline, 1) <> " " Then
				If strCtrlName <> "" Then
					parse_hpacucli = parse_hpacucli & strCtrlName & " " & strCtrlBS & "/" & strCtrlCA & "/" & strCtrlCR & " "  & "(" & _
								strLString & "LD " & strLID & ": " & strLST & " [" & Trim(strPString) & "]" & ")"					
					Execute unset("strCtrlName strCtrlBS strCtrlCA strCtrlCR strLString strLID strLST strPString strPID strPST")
				End If
				strLookFor = "controller"
				strCtrlName = strLine
				strCtrlBS = "-"
				strCtrlCA = "-"
				strCtrlCR = "-"
			End If

			' Trim Spaces
			strLine = Trim(strLine)
			
			' Find a Controller states
			If Lcase(strLookFor) = "controller" Then
				Select Case Left(strLine, Instr(strLine, ": "))
					Case "Battery Status:"
						strCtrlBS = Trim(Right(strLine, Len(strLine) - Instr(strLine, ": ")))
						call set_exit_status(strCtrlBS)

					Case "Cache Status:"
						strCtrlCA = Trim(Right(strLine, Len(strLine) - Instr(strLine, ": ")))
						call set_exit_status(strCtrlCA)
						
					Case "Controller Status:"
						strCtrlCR = Trim(Right(strLine, Len(strLine) - Instr(strLine, ": ")))
						call set_exit_status(strCtrlCR)
				End Select
			End If
			
			' Find a Logical Drive
			If Left(strLine, Instr(strLine, ": ")) = "Array:" Then strLookFor = "array"
			
			If Left(strLine, Instr(strLine, ": ")) = "Logical Drive:" Then
				If strLID <> "" Then
					strLString = strLString & "LD " & strLID & ": " & strLST & " [" & Trim(strPString) & "], "
					Execute unset("strLID strLST strPString strPID strPST")
				End if
				strLookFor = "logdrive"
				strLID = Trim(Right(strLine, Len(strLine) - Instr(strLine, ": ")))
			End If
			
			If Lcase(strLookFor) = "logdrive" And  Left(strLine, Instr(strLine, ": ")) = "Status:" Then
				strLST = Trim(Right(strLine, Len(strLine) - Instr(strLine, ": ")))
				call set_exit_status(strLST)
			End If
			
			' Find a Physical Drive
			If Instr(strLine, "physicaldrive") > 0 Then
				strLookFor = "phydrive"
				strPID = Trim(Right(strLine, Len(strLine) - Len("physicaldrive")))
			End If
			
			If Lcase(strLookFor) = "phydrive" And  Left(strLine, Instr(strLine, ": ")) = "Status:" Then
				strPST = Trim(Right(strLine, Len(strLine) - Instr(strLine, ": ")))
				call set_exit_status(strPST)
				strPString = strPString & "(" & strPID & " " & strPST & ") "
				Execute unset("strPID strPST")
			End If				
		End If
	Next
	parse_hpacucli = parse_hpacucli & strCtrlName & " " & strCtrlBS & "/" & strCtrlCA & "/" & strCtrlCR & " "  & "(" & _
				strLString & "LD " & strLID & ": " & strLST & " [" & Trim(strPString) & "]" & ")"
End Function

