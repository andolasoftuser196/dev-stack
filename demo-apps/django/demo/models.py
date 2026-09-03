from django.db import models


class DemoNote(models.Model):
    """One model, so `dx db:migrate` has something to apply."""

    body = models.CharField(max_length=255)
    created_at = models.DateTimeField(auto_now_add=True)
