$root = "C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid\media\lua"

$classes = @{}
$methods = @()
$events = @()
$inheritance = @()

function Get-Scope($path)
{
    if ($path -match "[\\/]client[\\/]") { return "client" }
    elseif ($path -match "[\\/]server[\\/]") { return "server" }
    else { return "shared" }
}

Get-ChildItem $root -Recurse -Filter *.lua | ForEach-Object {

    $file = $_
    $scope = Get-Scope $file.FullName
    $lines = Get-Content $file.FullName

    foreach ($line in $lines)
    {
        $line = $line.Trim()

        # Class declaration
        if ($line -match "^([A-Za-z0-9_]+)\s*=\s*{}")
        {
            $class = $matches[1]

            $classes[$class] = @{
                scope = $scope
                file = $file.Name
            }
        }

        # Inheritance
        elseif ($line -match "^([A-Za-z0-9_]+)\s*=\s*([A-Za-z0-9_]+):derive")
        {
            $child = $matches[1]
            $parent = $matches[2]

            $inheritance += [PSCustomObject]@{
                scope = $scope
                child = $child
                parent = $parent
                file = $file.Name
            }
        }

        # Method Class:method
        elseif ($line -match "^function\s+([A-Za-z0-9_]+):([A-Za-z0-9_]+)")
        {
            $methods += [PSCustomObject]@{
                scope = $scope
                class = $matches[1]
                method = $matches[2]
                file = $file.Name
                type = "method"
            }
        }

        # Static method Class.method
        elseif ($line -match "^function\s+([A-Za-z0-9_]+)\.([A-Za-z0-9_]+)")
        {
            $methods += [PSCustomObject]@{
                scope = $scope
                class = $matches[1]
                method = $matches[2]
                file = $file.Name
                type = "static_method"
            }
        }

        # Table method
        elseif ($line -match "^([A-Za-z0-9_]+)\.([A-Za-z0-9_]+)\s*=\s*function")
        {
            $methods += [PSCustomObject]@{
                scope = $scope
                class = $matches[1]
                method = $matches[2]
                file = $file.Name
                type = "method"
            }
        }

        # Dynamic method ["name"]
        elseif ($line -match "^([A-Za-z0-9_]+)\[['""]([A-Za-z0-9_]+)['""]\]\s*=\s*function")
        {
            $methods += [PSCustomObject]@{
                scope = $scope
                class = $matches[1]
                method = $matches[2]
                file = $file.Name
                type = "dynamic"
            }
        }

        # Events
        elseif ($line -match "Events\.([A-Za-z0-9_]+)\.Add")
        {
            $events += [PSCustomObject]@{
                scope = $scope
                event = $matches[1]
                file = $file.Name
            }
        }
    }
}

# Nettoyage
$methods = $methods | Sort-Object scope,class,method,file -Unique
$events = $events | Sort-Object scope,event,file -Unique
$inheritance = $inheritance | Sort-Object child,parent -Unique

# Export
$methods | Export-Csv "pz_methods.csv" -NoTypeInformation
$events | Export-Csv "pz_events.csv" -NoTypeInformation
$inheritance | Export-Csv "pz_inheritance.csv" -NoTypeInformation

# UI classes uniquement
$uiClasses = $methods | Where-Object { $_.class -like "IS*" }

$uiClasses | Export-Csv "pz_ui_methods.csv" -NoTypeInformation

Write-Host "Analyse terminée"
Write-Host "Méthodes :" $methods.Count
Write-Host "Events :" $events.Count
Write-Host "Héritage :" $inheritance.Count
Write-Host "UI Methods :" $uiClasses.Count