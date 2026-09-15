<?php

namespace App\Service\Branding;

use App\Models\Forms\Form;
use App\Service\Billing\Feature;

class BrandingPolicy
{
    public function canRemoveBranding(Form $form, bool $requested): bool
    {
        if (!$requested) {
            return false;
        }

        // Venova customization: self-hosted instances don't need the paid
        // whitelabel license to honor a branding-removal toggle that was
        // actually requested (still gated by $requested above, since
        // FormResource round-trips this value into every form update and
        // FormCleaner separately resets an unlicensed no_branding=true,
        // which would otherwise surface a spurious downgrade warning on
        // every save).
        if (config('app.self_hosted')) {
            return true;
        }

        return $form->workspace?->hasFeature(Feature::BRANDING_REMOVAL) ?? false;
    }

    public function canRemoveFormBranding(Form $form): bool
    {
        return $this->canRemoveBranding($form, (bool) $form->no_branding);
    }
}
