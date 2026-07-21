package net.preibisch.bigstitcher.spark;

import java.util.Arrays;
import java.util.List;

import ij.ImageJ;
import mpicbg.spim.data.SpimDataException;
import mpicbg.spim.data.generic.sequence.BasicViewDescription;
import net.preibisch.bigstitcher.spark.abstractcmdline.AbstractBasic;
import net.preibisch.mvrecon.fiji.spimdata.SpimData2;
import net.preibisch.mvrecon.fiji.spimdata.XmlIoSpimData2;
import net.preibisch.mvrecon.fiji.spimdata.explorer.SelectedViewDescriptionListener;
import net.preibisch.stitcher.gui.StitchingExplorer;
import picocli.CommandLine;

/**
 * Opens the interactive BigStitcher GUI (the StitchingExplorer) on an existing
 * BigStitcher project XML, so the same dataset that the headless Spark tools read
 * and write can be defined, inspected, and verified visually.
 *
 * This mirrors the GUI that {@link SplitDatasets} pops up with {@code --displayResult}:
 * it starts ImageJ, opens the explorer on the loaded {@link SpimData2}, and keeps the
 * JVM alive until the window is closed (the listener below then exits).
 */
public class BigStitcherGUI extends AbstractBasic
{
	private static final long serialVersionUID = 8971649476761464032L;

	@Override
	public Void call() throws Exception
	{
		// Load with fetcher threads (unlike the 0 used for Spark jobs) so the GUI can
		// actually render image data; this also assigns xmlURI in loadSpimData2().
		final SpimData2 data = this.loadSpimData2( Runtime.getRuntime().availableProcessors() );

		if ( data == null )
			throw new IllegalArgumentException( "Couldn't load SpimData XML project: " + xmlURIString );

		System.out.println( "Opening BigStitcher GUI for: " + xmlURI );

		new ImageJ();

		final StitchingExplorer< SpimData2 > explorer =
				new StitchingExplorer<>( data, xmlURI, new XmlIoSpimData2() );
		explorer.getFrame().toFront();

		explorer.addListener( new SelectedViewDescriptionListener< SpimData2 >()
		{
			@Override
			public void updateContent( final SpimData2 data ) {}

			@Override
			public void selectedViewDescriptions( final List< List< BasicViewDescription< ? > > > viewDescriptions ) {}

			@Override
			public void save() {}

			@Override
			public void quit()
			{
				System.out.println( "quitting GUI." );
				System.exit( 0 );
			}
		} );

		// The explorer runs on the Swing/AWT event thread; block here so the JVM stays
		// alive. The quit() listener above calls System.exit when the window is closed.
		try
		{
			Thread.sleep( Long.MAX_VALUE );
		}
		catch ( final InterruptedException e )
		{
			System.err.println( "BigStitcherGUI: main thread woken up: " + e );
		}

		return null;
	}

	public static void main( final String... args ) throws SpimDataException
	{
		System.out.println( Arrays.toString( args ) );
		System.exit( new CommandLine( new BigStitcherGUI() ).execute( args ) );
	}
}
