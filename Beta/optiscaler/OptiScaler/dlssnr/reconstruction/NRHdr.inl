// Native view binding extracted without behavior changes from the reviewed R7 build.
        // Experimental. 0 off (soft knee), 1 Neutwo + our composition, 2 Neutwo + pure-inverse replace,
        // 3 hybrid+composed, 4 hybrid+replace (identity midtones + unclipped highlights). Always shown.
        static const char* reversibleNames[] = { "Off (soft knee)", "Neutwo proxy + composed",
                                                 "Neutwo proxy + replace", "Hybrid proxy + composed",
                                                 "Hybrid proxy + replace" };
        int reversible = (int) config->DlssNrReversibleMode.value_or_default();
        if (reversible < 0 || reversible > 4)
            reversible = 0;
        if (ImGui::Combo("HDR mapping (experimental)", &reversible, reversibleNames,
                         IM_ARRAYSIZE(reversibleNames)))
            config->DlssNrReversibleMode = (uint32_t) reversible;

        HelpMarker("Choose how HDR brightness is mapped for NR.\nSoft knee compresses highlights. Neutwo uses a reversible curve. Hybrid preserves midtones and compresses highlights.\nComposed uses the strength and highlight controls. Replace bypasses them and may flicker.");


