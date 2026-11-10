$ErrorActionPreference='Stop'
# GetNewClosure() callbacks run in a dynamic module: manager functions and
# script-scope variables are not visible there, and $script: writes go to the
# module. Callbacks must use captured command blocks and context objects.
$functions=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach($file in Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1'){
 $ast=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$null,[ref]$null)
 foreach($definition in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)){[void]$functions.Add($definition.Name)}
}
$scriptVariables=@('status','store','form','path','Payload')
$failures=@();$checked=0
foreach($name in @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1'|Where-Object Name -notlike '*.test.ps1'|ForEach-Object Name)){
 $errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $name),[ref]$null,[ref]$errors)
 if($errors.Count){throw ("Parse error in ${name}: "+$errors[0].Message)}
 $closures=$ast.FindAll({param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member.Value -eq 'GetNewClosure' -and $n.Expression -is [Management.Automation.Language.ScriptBlockExpressionAst]},$true)
 foreach($closure in $closures){$checked++
  $body=$closure.Expression.ScriptBlock
  # Locals assigned in the enclosing function are captured; only flag names
  # that the enclosing function does not assign itself.
  $enclosing=$closure.Parent;while($enclosing -and $enclosing -isnot [Management.Automation.Language.FunctionDefinitionAst]){$enclosing=$enclosing.Parent}
  $assigned=@()
  if($enclosing){$assigned=@($enclosing.Body.FindAll({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [Management.Automation.Language.VariableExpressionAst]},$true)|ForEach-Object {$_.Left.VariablePath.UserPath})+@($enclosing.Parameters|ForEach-Object {$_.Name.VariablePath.UserPath})+@(if($enclosing.Body.ParamBlock){$enclosing.Body.ParamBlock.Parameters|ForEach-Object {$_.Name.VariablePath.UserPath}})}
  $line=$closure.Extent.StartLineNumber
  foreach($command in $body.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst]},$true)){
   $commandName=$command.GetCommandName()
   if($commandName -and $functions.Contains($commandName)){$failures+="${name}:${line} closure calls manager function '$commandName' by name"}
  }
  foreach($variable in $body.FindAll({param($n) $n -is [Management.Automation.Language.VariableExpressionAst]},$true)){
   $path=$variable.VariablePath
   if($path.IsScript -and $variable.Parent -is [Management.Automation.Language.AssignmentStatementAst] -and $variable.Parent.Left -eq $variable){$failures+="${name}:${line} closure writes `$script:$($path.UserPath)"}
   elseif($path.IsUnqualified -and $path.UserPath -cin $scriptVariables -and $path.UserPath -notin $assigned){$failures+="${name}:${line} closure reads script variable `$$($path.UserPath)"}
  }
 }
}
if($failures.Count){$failures|ForEach-Object {Write-Output $_};throw ("GetNewClosure scope violations: "+$failures.Count)}
Write-Output ('Closure scope tests passed: '+$checked+' GetNewClosure callbacks checked.')
