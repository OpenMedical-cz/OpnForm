<?php

namespace App\Service\Branding;

use App\Models\Forms\Form;
use App\Service\Billing\Feature;

class BrandingPolicy
{
    public function canRemoveBranding(Form $form, bool $requested): bool
    {
        // Venova customization: self-hosted instances never show OpnForm branding,
        // regardless of the stored per-form/per-template toggle (matches the
        // form-page "Powered by OpnForm" badge removal).
        if (config('app.self_hosted')) {
            return true;
        }

        return $requested && ($form->workspace?->hasFeature(Feature::BRANDING_REMOVAL) ?? false);
    }

    public function canRemoveFormBranding(Form $form): bool
    {
        return $this->canRemoveBranding($form, (bool) $form->no_branding);
    }
}
