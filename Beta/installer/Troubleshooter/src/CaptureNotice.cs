using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Threading;
using System.Windows.Forms;
namespace OptiShade.TesterKit {
public sealed class NoticeState {
    public volatile string Message;
    public volatile bool Complete;
    public void Update(string message){Message=message;}
    public void Finish(string message){Message=message;Complete=true;}
}
public sealed class CaptureNotice : Form {
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams { get { var p=base.CreateParams;p.ExStyle|=0x08000000|0x00000080;return p; } }
    readonly NoticeState state;
    readonly Label body;
    readonly System.Windows.Forms.Timer timer;
    double angle;DateTime finished=DateTime.MaxValue;
    public CaptureNotice(NoticeState value) {
        state=value;Text="OptiShade diagnostics";FormBorderStyle=FormBorderStyle.None;ShowInTaskbar=false;
        TopMost=true;BackColor=Color.FromArgb(16,15,28);ForeColor=Color.FromArgb(230,220,245);
        ClientSize=new Size(480,290);StartPosition=FormStartPosition.Manual;DoubleBuffered=true;
        var screen=Screen.PrimaryScreen.WorkingArea;Location=new Point(screen.Left+(screen.Width-ClientSize.Width)/2,screen.Top+(screen.Height-ClientSize.Height)/2);
        Controls.Add(new Label{Text="OptiShade  /  Diagnostics",ForeColor=Color.FromArgb(175,105,255),Font=new Font("Segoe UI",11,FontStyle.Bold),Bounds=new Rectangle(20,16,395,25)});
        body=new Label{Text=value.Message,Font=new Font("Segoe UI",10),Bounds=new Rectangle(20,55,440,180)};Controls.Add(body);
        timer=new System.Windows.Forms.Timer{Interval=80};
        timer.Tick+=(s,e)=>{
            body.Text=state.Message;angle=(angle+16)%360;Invalidate();
            if(state.Complete){if(finished==DateTime.MaxValue)finished=DateTime.UtcNow;if((DateTime.UtcNow-finished).TotalSeconds>=25)Close();}
        };timer.Start();
    }
    protected override void OnPaint(PaintEventArgs e){
        base.OnPaint(e);var g=e.Graphics;g.SmoothingMode=SmoothingMode.AntiAlias;
        using(var border=new Pen(Color.FromArgb(66,52,84)))g.DrawRectangle(border,0,0,ClientSize.Width-1,ClientSize.Height-1);
        for(int i=0;i<10;i++)using(var wave=new Pen(Color.FromArgb(100-i*8,157,66,255),1))
            g.DrawBezier(wave,new PointF(20,274),new PointF(150,240+i*2),new PointF(300,308-i*2),new PointF(460,272));
        using(var track=new SolidBrush(Color.FromArgb(57,39,77)))g.FillRectangle(track,20,252,440,6);
        using(var purple=new SolidBrush(Color.FromArgb(174,88,255))) {
            if(!state.Complete)g.FillRectangle(purple,20+(int)(angle/360*330),252,110,6);
            else g.FillRectangle(purple,20,252,440,6);
        }
        using(var pen=new Pen(Color.FromArgb(174,88,255),3)) {
            if(!state.Complete)g.DrawArc(pen,438,17,23,23,(float)angle,250);
            else {g.DrawLine(pen,439,28,447,35);g.DrawLine(pen,447,35,460,20);}
        }
    }
    protected override void Dispose(bool disposing){if(disposing)timer.Dispose();base.Dispose(disposing);}
    public static NoticeState Begin(string message) {
        var state=new NoticeState{Message=message};
        var thread=new Thread(()=>{try{using(var form=new CaptureNotice(state))Application.Run(form);}catch{}});
        // The notification must never outlive the watcher that owns collection.
        // An exception before Finish or game exit must not strand a foreground UI thread.
        thread.IsBackground=true;thread.SetApartmentState(ApartmentState.STA);thread.Start();return state;
    }
}
}
