import subprocess,pathlib
r=pathlib.Path.cwd();d=r/'tests/reconstruction/fixtures/cockpit-v080';out=r/'test-results/cockpit-official-fixture';out.mkdir(parents=True,exist_ok=True);im=r/'Beta/reshade/deps/imgui';src=r/'Beta/reshade/source'
base=['cl','/nologo','/std:c++17','/EHsc','/utf-8','/DNOMINMAX','/I'+str(im),'/I'+str(src),'/I'+str(r/'Beta/reshade/include'),'/I'+str(d),'/Fo:'+str(out)+'\\']
subprocess.run(base+['/LD',str(d/'fixture.cpp'),'/Fe:'+str(out/'fixture.dll'),'/link','shell32.lib','user32.lib'],check=True)
subprocess.run(base+['/DRESHADE_API_LIBRARY_EXPORT','/DRESHADE_ADDON=1','/DRESHADE_GUI=1',str(d/'host.cpp'),str(src/'imgui_function_table.cpp'),str(src/'imgui_function_table_19250.cpp'),*[str(im/n) for n in ['imgui.cpp','imgui_draw.cpp','imgui_tables.cpp','imgui_widgets.cpp']],'/Fe:'+str(out/'host.exe'),'/link','user32.lib','shell32.lib','imm32.lib','dwmapi.lib'],check=True)
subprocess.run([str(out/'host.exe'),str(out/'fixture.dll')],check=True)

# Current official panel uses C++20 defaulted equality in its status type.
d=r/'tests/reconstruction/fixtures/cockpit-v104'
out=r/'test-results/cockpit-official-v104-fixture';out.mkdir(parents=True,exist_ok=True)
base=['cl','/nologo','/std:c++20','/EHsc','/utf-8','/DNOMINMAX','/I'+str(im),'/I'+str(src),'/I'+str(r/'Beta/reshade/include'),'/I'+str(d),'/Fo:'+str(out)+'\\']
subprocess.run(base+['/LD',str(d/'fixture.cpp'),'/Fe:'+str(out/'fixture.dll'),'/link','shell32.lib','user32.lib'],check=True)
subprocess.run(base+['/DRESHADE_API_LIBRARY_EXPORT','/DRESHADE_ADDON=1','/DRESHADE_GUI=1',str(d/'host.cpp'),str(src/'imgui_function_table.cpp'),str(src/'imgui_function_table_19250.cpp'),*[str(im/n) for n in ['imgui.cpp','imgui_draw.cpp','imgui_tables.cpp','imgui_widgets.cpp']],'/Fe:'+str(out/'host.exe'),'/link','user32.lib','shell32.lib','imm32.lib','dwmapi.lib'],check=True)
subprocess.run([str(out/'host.exe'),str(out/'fixture.dll')],check=True)
