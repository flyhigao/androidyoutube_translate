.class public final Lapp/yydarlinker/deepseekcaptions/WarmPing;
.super Ljava/lang/Object;
.source "WarmPing.java"


# direct methods
.method private constructor <init>()V
    .registers 1

    invoke-direct {p0}, Ljava/lang/Object;-><init>()V

    return-void
.end method

.method public static ping(Landroid/content/Context;Ljava/lang/String;)V
    .registers 5

    :try_start_0
    invoke-static {p0}, Lapp/yydarlinker/deepseekcaptions/DeepSeekConfig;->baseUrl(Landroid/content/Context;)Ljava/lang/String;
    move-result-object v0

    if-eqz v0, :cond_skip

    invoke-virtual {v0}, Ljava/lang/String;->length()I
    move-result v1

    if-nez v1, :cond_build

    :cond_skip
    return-void

    :cond_build
    const-string v1, "/v1/plain/chat/completions"

    const-string v2, "/yt/warm"

    invoke-virtual {v0, v1, v2}, Ljava/lang/String;->replace(Ljava/lang/CharSequence;Ljava/lang/CharSequence;)Ljava/lang/String;
    move-result-object v0

    const-string v1, "/v1/chat/completions"

    const-string v2, "/yt/warm"

    invoke-virtual {v0, v1, v2}, Ljava/lang/String;->replace(Ljava/lang/CharSequence;Ljava/lang/CharSequence;)Ljava/lang/String;
    move-result-object v0

    new-instance v1, Ljava/lang/StringBuilder;

    invoke-direct {v1}, Ljava/lang/StringBuilder;-><init>()V

    invoke-virtual {v1, v0}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;

    const-string v2, "?v="

    invoke-virtual {v1, v2}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;

    invoke-virtual {v1, p1}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;

    invoke-virtual {v1}, Ljava/lang/StringBuilder;->toString()Ljava/lang/String;
    move-result-object v0

    new-instance v1, Ljava/lang/Thread;

    new-instance v2, Lapp/yydarlinker/deepseekcaptions/WarmPing$1;

    invoke-direct {v2, v0}, Lapp/yydarlinker/deepseekcaptions/WarmPing$1;-><init>(Ljava/lang/String;)V

    invoke-direct {v1, v2}, Ljava/lang/Thread;-><init>(Ljava/lang/Runnable;)V

    invoke-virtual {v1}, Ljava/lang/Thread;->start()V
    :try_end_0
    .catchall {:try_start_0 .. :try_end_0} :catchall_0

    return-void

    :catchall_0
    move-exception v0

    return-void
.end method
